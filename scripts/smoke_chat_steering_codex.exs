# CHAT_LIVE_STEERING_ROADMAP Phase 3 acceptance: does Codex, through
# `Chat.submit/3`, get BOTH of the things it lacked — mid-turn steering and
# conversation continuity?
#
#   mix run scripts/smoke_chat_steering_codex.exs
#
# The codex counterpart to `smoke_chat_steering.exs`, and the parity check the
# operator asked for: Codex must work as well as Claude, not merely be present.
# Opt-in, drives the operator's real logged-in `codex`, and costs money.
#
# No side effects: every step is a `sleep` and an `echo` to stdout.

require Logger

alias BusterClaw.Agent.Chat

unless System.find_executable("codex") do
  IO.puts("codex is not on PATH — this smoke needs the operator's real CLI.")
  System.halt(1)
end

Application.put_env(:buster_claw, :chat_live_steering_enabled, true)

conv = "smoke-codex-#{System.unique_integer([:positive])}"
Chat.subscribe(conv)

{:ok, pid} =
  Chat.start_link(
    conv_id: conv,
    agent: :codex,
    persist: false,
    audit: false,
    timeout_ms: 5 * 60 * 1000
  )

task = """
Do exactly these three steps in order, each as its own separate shell command, \
and say one short sentence before each one:

1. sleep 8 && echo step-one
2. sleep 8 && echo step-two
3. sleep 8 && echo step-three

Do not combine them into one command. Do not run them in the background.
"""

steer = """
CHANGE OF PLAN: stop the three-step sequence immediately. Do not run any \
remaining steps. Instead run this single shell command and then finish:

echo redirected
"""

defmodule Smoke do
  def collect(conv, state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agent_chat, ^conv, {:message, %{role: role, text: text}}} ->
        stamp = System.monotonic_time(:millisecond) - state.started
        IO.puts("[#{stamp}ms] #{role}: #{one_line(text)}")

        state
        |> record(role, text, stamp)
        |> maybe_steer(conv, role, text)
        |> then(&collect(conv, &1, deadline))

      {:agent_chat, ^conv, {:status, :idle}} ->
        IO.puts("\n--- idle ---")
        state

      {:agent_chat, ^conv, _other} ->
        collect(conv, state, deadline)
    after
      remaining ->
        IO.puts("\n!!! deadline reached")
        state
    end
  end

  defp record(state, :tool, text, stamp), do: %{state | tools: state.tools ++ [{stamp, text}]}
  defp record(state, :meta, _text, _stamp), do: %{state | results: state.results + 1}
  defp record(state, :error, text, _stamp), do: %{state | errors: state.errors ++ [text]}
  defp record(state, _role, _text, _stamp), do: state

  defp maybe_steer(%{steered: nil} = state, conv, :tool, text) do
    if String.contains?(text, "sleep 8") do
      IO.puts("\n--- first step running; steering now ---")
      result = Chat.submit(conv, state.steer_text, delivery: :steer)
      IO.puts("--- Chat.submit(delivery: :steer) -> #{inspect(result)} ---\n")
      %{state | steered: result}
    else
      state
    end
  end

  defp maybe_steer(state, _conv, _role, _text), do: state

  defp one_line(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 110)

  def run(conv, state, budget) do
    collect(conv, state, System.monotonic_time(:millisecond) + budget)
  end
end

blank = fn steer_text ->
  %{
    started: System.monotonic_time(:millisecond),
    tools: [],
    results: 0,
    errors: [],
    steered: nil,
    steer_text: steer_text
  }
end

IO.puts("conversation: #{conv}\n--- turn 1: the three-step task, steered mid-flight ---\n")
{:ok, :started} = Chat.submit(conv, task, delivery: :auto)
first = Smoke.run(conv, blank.(steer), 5 * 60 * 1000)

thread = :sys.get_state(pid).session_id
IO.puts("\nthread after turn 1: #{inspect(thread)}")

# --- turn 2: continuity ------------------------------------------------------
#
# The gap `codex exec` left. A second turn must be able to refer to the first;
# before app-server it could not, because every turn was a fresh process.

IO.puts("\n--- turn 2: does it remember turn 1? ---\n")

{:ok, :started} =
  Chat.submit(
    conv,
    "Without running anything, what was the FIRST shell command you ran in this conversation? Answer in one short sentence.",
    delivery: :auto
  )

second = Smoke.run(conv, blank.(steer), 3 * 60 * 1000)
thread_after = :sys.get_state(pid).session_id

tool_text = Enum.map_join(first.tools, "\n", fn {_at, t} -> t end)

steered? = first.steered == {:ok, :steered}
redirected? = String.contains?(tool_text, "redirected")
skipped? = not String.contains?(tool_text, "step-three")
one_turn? = first.results <= 1
same_thread? = is_binary(thread) and thread == thread_after
remembered? = second.results >= 1 and second.errors == []

pass? = steered? and redirected? and skipped? and one_turn? and same_thread? and remembered?

IO.puts("\n" <> String.duplicate("=", 68))
IO.puts("VERDICT: #{if pass?, do: "PASS — codex steers AND remembers", else: "FAIL"}")
IO.puts(String.duplicate("=", 68))
IO.puts("  STEERING")
IO.puts("    Chat.submit returned:  #{inspect(first.steered)}   (must be {:ok, :steered})")
IO.puts("    redirect ran:          #{redirected?}")
IO.puts("    step three skipped:    #{skipped?}")
IO.puts("    turns completed:       #{first.results}   (must be 1)")
IO.puts("  CONTINUITY")
IO.puts("    thread id:             #{inspect(thread)}")
IO.puts("    same thread on turn 2: #{same_thread?}")
IO.puts("    turn 2 answered:       #{remembered?}")
IO.puts("    errors:                #{inspect(first.errors ++ second.errors)}")
IO.puts("\n  turn 1 tool calls, in order:")
Enum.each(first.tools, fn {at, t} -> IO.puts("    [#{at}ms] #{String.slice(t, 0, 90)}") end)
IO.puts("\n  NOTE: read turn 2's answer above — it should name `sleep 8 && echo step-one`.")
IO.puts("  A codex chat before this phase could not answer it at all.")

System.halt(if(pass?, do: 0, else: 1))
