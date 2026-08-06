# CHAT_LIVE_STEERING_ROADMAP Phase 2 acceptance: during a real multi-step Claude
# task, does an operator correction submitted through `Chat.submit/3` reach the
# SAME active turn and change the next model action — with no OS-process restart?
#
#   mix run scripts/smoke_chat_steering.exs
#
# Opt-in and never part of `mix precommit`: it drives the operator's real,
# logged-in `claude` and costs money. The unit suite covers the lifecycle with
# fakes; this is the one that proves the whole path.
#
# The probe (`scripts/probe_claude_duplex.exs`) already established that the
# HARNESS steers. This establishes that Buster Claw does — argv, transport,
# turn references, delivery modes, and the transcript projection included.
#
# No side effects: every step is a `sleep` and an `echo` to stdout. Nothing is
# written to the workspace, so this is safe to run against a real install.

require Logger

alias BusterClaw.Agent.Chat

task = """
Do exactly these three steps in order, each as its own separate Bash tool call, \
and say one short sentence before each one:

1. sleep 8 && echo step-one
2. sleep 8 && echo step-two
3. sleep 8 && echo step-three

Do not combine them into one command. Do not run them in the background.
"""

steer = """
CHANGE OF PLAN: stop the three-step sequence immediately. Do not run any \
remaining steps. Instead run this single Bash command and then finish:

echo redirected
"""

unless System.find_executable("claude") do
  IO.puts("claude is not on PATH — this smoke needs the operator's real CLI.")
  System.halt(1)
end

# The whole point: without this the conversation gets the one-shot transport and
# there is nothing to steer.
Application.put_env(:buster_claw, :chat_live_steering_enabled, true)

conv = "smoke-steering-#{System.unique_integer([:positive])}"
Chat.subscribe(conv)

{:ok, _pid} =
  Chat.start_link(
    conv_id: conv,
    agent: :claude,
    # No transcript rows and no audit events: this is a harness check, not a
    # conversation the operator asked for.
    persist: false,
    audit: false,
    timeout_ms: 5 * 60 * 1000
  )

IO.puts("conversation: #{conv}")
IO.puts("submitting the three-step task…\n")

{:ok, :started} = Chat.submit(conv, task, delivery: :auto)

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
        IO.puts("\n--- conversation idle ---")
        state

      {:agent_chat, ^conv, _other} ->
        collect(conv, state, deadline)
    after
      remaining ->
        IO.puts("\n!!! deadline reached")
        state
    end
  end

  defp record(state, :tool, text, stamp),
    do: %{state | tools: state.tools ++ [{stamp, text}]}

  defp record(state, :meta, _text, _stamp), do: %{state | results: state.results + 1}
  defp record(state, :error, text, _stamp), do: %{state | errors: state.errors ++ [text]}
  defp record(state, _role, _text, _stamp), do: state

  # Steer once, as soon as the first step is genuinely running — the same
  # boundary the probe used.
  defp maybe_steer(%{steered: nil} = state, conv, :tool, text) do
    if String.contains?(text, "sleep 8") do
      IO.puts("\n--- first step running; steering now ---")
      result = Chat.submit(conv, state.steer_text, delivery: :steer)
      IO.puts("--- Chat.submit(delivery: :steer) -> #{inspect(result)} ---\n")
      %{state | steered: result, steered_at: System.monotonic_time(:millisecond) - state.started}
    else
      state
    end
  end

  defp maybe_steer(state, _conv, _role, _text), do: state

  defp one_line(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 110)
end

started = System.monotonic_time(:millisecond)

state =
  Smoke.collect(
    conv,
    %{
      started: started,
      tools: [],
      results: 0,
      errors: [],
      steered: nil,
      steered_at: nil,
      steer_text: steer
    },
    started + 5 * 60 * 1000
  )

tool_text = Enum.map_join(state.tools, "\n", fn {_at, t} -> t end)

redirected? = String.contains?(tool_text, "redirected")
step_three? = String.contains?(tool_text, "step-three")
one_turn? = state.results == 1
steered? = state.steered == {:ok, :steered}

IO.puts("\n" <> String.duplicate("=", 68))

IO.puts(
  "VERDICT: #{if redirected? and not step_three? and one_turn? and steered?, do: "PASS — steered inside the active turn", else: "FAIL"}"
)

IO.puts(String.duplicate("=", 68))
IO.puts("  Chat.submit returned:  #{inspect(state.steered)}   (must be {:ok, :steered})")
IO.puts("  steered at:            #{state.steered_at || "-"}ms")
IO.puts("  redirect ran:          #{redirected?}")
IO.puts("  step three skipped:    #{not step_three?}")
IO.puts("  turns completed:       #{state.results}   (must be 1 — one turn, not two)")
IO.puts("  errors:                #{inspect(state.errors)}")
IO.puts("\n  tool calls, in order:")
Enum.each(state.tools, fn {at, t} -> IO.puts("    [#{at}ms] #{String.slice(t, 0, 90)}") end)

System.halt(if(redirected? and not step_three? and one_turn? and steered?, do: 0, else: 1))
