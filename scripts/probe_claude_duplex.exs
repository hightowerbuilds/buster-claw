# CHAT_LIVE_STEERING_ROADMAP Phase 0, probes 1 and 2: can a long-lived
# `claude -p --input-format stream-json` process accept a second user message
# INTO the turn that is already running?
#
#   elixir scripts/probe_claude_duplex.exs [--inject-on tool|text] [--keep]
#
# Deliberately NOT `mix run`: this must not boot the app or touch the dev DB.
# It shells out to the operator's real, logged-in `claude`, so it is opt-in and
# never runs in CI.
#
# It is also the prototype for Phase 2's duplex Port opener. The shell wrapper
# below is `AgentRunner.open_port/4`'s verbatim, minus `</dev/null` — that one
# redirect is the entire reason the shipped chat process cannot be steered, and
# keeping the `perl setpgrp` leader is what lets `kill_port/1` still reap the
# tool subprocess group.
#
# The run happens in a disposable temp workspace and every step is a local
# `echo` into that directory: no network, no external side effects.

# --- what we are measuring -------------------------------------------------
#
# Turn 1 asks for three slow, separately-observable Bash steps. Partway through
# we write a second JSONL user message telling it to abandon the remaining
# steps and do something else instead. Then:
#
#   STEERED      redirect.txt exists AND step3.txt does not AND both happened
#                before the first `result` event  -> the message joined the
#                active turn
#   NEXT_TURN    the redirect only took effect after a `result` boundary
#   IGNORED      turn 1 ran to completion untouched
#
# Turn 2 (sent after the first `result`) answers the lifecycle question Phase 2
# depends on: does the OS process survive a completed turn and accept another?

defmodule Probe do
  @inject_marker "CHANGE OF PLAN"

  def run(opts) do
    inject_on = Keyword.get(opts, :inject_on, "tool")
    keep? = Keyword.get(opts, :keep, false)

    workspace =
      Path.join(System.tmp_dir!(), "bc-probe-claude-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    binary =
      System.find_executable("claude") ||
        raise "claude is not on PATH — this probe needs the operator's real CLI"

    IO.puts("workspace: #{workspace}")
    IO.puts("binary:    #{binary}")
    IO.puts("inject on: first #{inject_on} event of turn 1\n")

    port = open_duplex(binary, argv(), workspace)
    started = now()

    state = %{
      port: port,
      started: started,
      buf: "",
      trace: [],
      injected_at: nil,
      inject_on: inject_on,
      results: 0,
      turn2_sent?: false,
      workspace: workspace
    }

    send_user(state, turn1_prompt(), "turn-1")
    state = loop(state, now() + 240_000)

    report(state)
    write_trace(state)

    kill(port)
    unless keep?, do: File.rm_rf!(workspace)
    if keep?, do: IO.puts("\nworkspace kept: #{workspace}")
  end

  # --- argv ----------------------------------------------------------------

  # `--replay-user-messages` is the acceptance receipt the roadmap wants: it
  # re-emits our stdin messages on stdout, which is the only evidence available
  # that the harness took the message at all. Without it, "accepted" would be
  # an assumption.
  defp argv do
    [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--replay-user-messages",
      "--permission-mode",
      "bypassPermissions"
    ]
  end

  defp turn1_prompt do
    """
    Do exactly these three steps in order, each as its own separate Bash tool \
    call, and write one short sentence before each one:

    1. sleep 8 && echo step-one > step1.txt
    2. sleep 8 && echo step-two > step2.txt
    3. sleep 8 && echo step-three > step3.txt

    Do not combine them into one command. Do not run them in the background.
    """
  end

  defp inject_prompt do
    """
    #{@inject_marker}: stop the three-step sequence immediately. Do not run any \
    remaining steps. Instead run this single Bash command and then finish:

    echo redirected > redirect.txt
    """
  end

  # --- the duplex port -----------------------------------------------------

  defp open_duplex(binary, args, cwd) do
    # AgentRunner.open_port/4 verbatim EXCEPT the missing `</dev/null`.
    cmd = ~s|exec perl -e 'setpgrp(0,0); exec @ARGV or exit 127' "$@" 2>&1|
    shell_args = ["-lc", cmd, "sh", binary | args]

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :hide,
      {:args, shell_args},
      {:cd, String.to_charlist(cwd)}
    ])
  end

  # The stream-json input line. Phase 2 centralizes this encoder; here it is
  # inline so the probe records exactly what was on the wire.
  defp send_user(state, text, label) do
    line =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{"role" => "user", "content" => text}
      })

    IO.puts(">>> [#{ms(state)}ms] sent #{label} (#{byte_size(line)} bytes)")
    Port.command(state.port, line <> "\n")
  end

  # --- receive loop --------------------------------------------------------

  defp loop(state, deadline) do
    remaining = max(deadline - now(), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        {lines, buf} = split_lines(state.buf <> data)
        state = Enum.reduce(lines, %{state | buf: buf}, &observe/2)
        if done?(state), do: state, else: loop(state, deadline)

      {port, {:exit_status, code}} when port == state.port ->
        IO.puts("!!! [#{ms(state)}ms] process EXITED with status #{code}")
        %{state | trace: [{ms(state), :exit, %{"status" => code}} | state.trace]}
    after
      remaining ->
        IO.puts("!!! [#{ms(state)}ms] probe deadline reached")
        state
    end
  end

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {lines, [rest]} = Enum.split(parts, length(parts) - 1)
    {lines, rest}
  end

  defp observe(line, state) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = event} -> observe_event(event, state)
      _ -> observe_raw(line, state)
    end
  end

  defp observe_event(event, state) do
    at = ms(state)
    state = %{state | trace: [{at, :event, event} | state.trace]}

    IO.puts("<<< [#{at}ms] #{describe(event)}")

    state
    |> maybe_inject(event)
    |> maybe_advance(event)
  end

  # Non-JSON output is how claude reports the failures that matter most (not
  # logged in, bad config). Chat's `raw_tail` exists for exactly these lines.
  defp observe_raw(line, state) do
    case String.trim(line) do
      "" ->
        state

      text ->
        IO.puts("<<< [#{ms(state)}ms] RAW: #{String.slice(text, 0, 200)}")
        %{state | trace: [{ms(state), :raw, %{"line" => text}} | state.trace]}
    end
  end

  # Inject once, at the requested boundary of turn 1 — probe 2's timing
  # question is whether that boundary changes whether the message lands.
  defp maybe_inject(%{injected_at: nil, results: 0, inject_on: on} = state, event) do
    if boundary?(on, event) do
      IO.puts("--- injecting now (#{on} boundary of turn 1) ---")
      send_user(state, inject_prompt(), "steer")
      %{state | injected_at: ms(state)}
    else
      state
    end
  end

  defp maybe_inject(state, _event), do: state

  defp boundary?("tool", %{"type" => "assistant", "message" => %{"content" => blocks}})
       when is_list(blocks),
       do: Enum.any?(blocks, &(is_map(&1) and &1["type"] == "tool_use"))

  defp boundary?("text", %{"type" => "assistant", "message" => %{"content" => blocks}})
       when is_list(blocks),
       do: Enum.any?(blocks, &(is_map(&1) and &1["type"] == "text"))

  defp boundary?(_on, _event), do: false

  # A `result` event is the roadmap's claimed TURN boundary (not transport
  # completion). After the first one, send a second turn down the same stdin:
  # if it is answered, the long-lived conversation process is real.
  defp maybe_advance(%{results: 0, turn2_sent?: false} = state, %{"type" => "result"}) do
    state = %{state | results: 1}
    IO.puts("--- first result seen; testing turn 2 on the same process ---")
    send_user(state, "Reply with exactly: TURN-TWO-OK", "turn-2")
    %{state | turn2_sent?: true}
  end

  defp maybe_advance(state, %{"type" => "result"}),
    do: %{state | results: state.results + 1}

  defp maybe_advance(state, _event), do: state

  defp done?(%{results: n}) when n >= 2, do: true
  defp done?(_state), do: false

  defp describe(%{"type" => "system", "subtype" => sub} = e),
    do: "system/#{sub} session=#{short(e["session_id"])} caps=#{inspect(capability_keys(e))}"

  defp describe(%{"type" => "assistant", "message" => %{"content" => blocks}})
       when is_list(blocks) do
    summary =
      Enum.map_join(blocks, ", ", fn
        %{"type" => "text", "text" => t} -> "text(#{String.slice(t, 0, 60) |> one_line()})"
        %{"type" => "tool_use", "name" => n, "input" => i} -> "tool_use(#{n}: #{tool_brief(i)})"
        %{"type" => t} -> t
        _ -> "?"
      end)

    "assistant #{summary}"
  end

  defp describe(%{"type" => "user", "message" => %{"content" => c}}) when is_binary(c),
    do: "user REPLAY #{one_line(String.slice(c, 0, 70))}"

  defp describe(%{"type" => "user", "message" => %{"content" => blocks}}) when is_list(blocks) do
    kinds = Enum.map_join(blocks, ",", &(is_map(&1) && &1["type"]))
    "user (#{kinds})"
  end

  defp describe(%{"type" => "result"} = e),
    do:
      "RESULT subtype=#{e["subtype"]} is_error=#{e["is_error"]} turns=#{e["num_turns"]} cost=#{e["total_cost_usd"]}"

  defp describe(%{"type" => t}), do: t
  defp describe(_), do: "?"

  # The roadmap wants capability negotiation rather than version sniffing —
  # record whether the init event actually carries anything to negotiate with.
  defp capability_keys(%{"capabilities" => caps}) when is_map(caps), do: Map.keys(caps)
  defp capability_keys(%{"capabilities" => caps}) when is_list(caps), do: caps
  defp capability_keys(_), do: nil

  defp tool_brief(%{"command" => c}), do: one_line(String.slice(c, 0, 60))
  defp tool_brief(%{"file_path" => p}), do: Path.basename(p)
  defp tool_brief(_), do: ""

  defp one_line(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()
  defp short(nil), do: "-"
  defp short(id), do: String.slice(id, 0, 8)

  # --- verdict -------------------------------------------------------------

  defp report(state) do
    ws = state.workspace
    files = ~w(step1.txt step2.txt step3.txt redirect.txt)
    present = Enum.filter(files, &File.exists?(Path.join(ws, &1)))

    first_result_at =
      state.trace
      |> Enum.reverse()
      |> Enum.find_value(fn
        {at, :event, %{"type" => "result"}} -> at
        _ -> nil
      end)

    redirect_at =
      state.trace
      |> Enum.reverse()
      |> Enum.find_value(fn
        {at, :event, %{"type" => "assistant", "message" => %{"content" => blocks}}}
        when is_list(blocks) ->
          if Enum.any?(blocks, fn b ->
               is_map(b) and b["type"] == "tool_use" and
                 String.contains?(inspect(b["input"]), "redirect.txt")
             end),
             do: at

        _ ->
          nil
      end)

    verdict =
      cond do
        is_nil(redirect_at) -> "IGNORED — the injected message never took effect"
        is_nil(first_result_at) -> "INCONCLUSIVE — no result boundary observed"
        redirect_at < first_result_at -> "STEERED — redirect ran inside the ACTIVE turn"
        true -> "NEXT_TURN — redirect only ran after a result boundary"
      end

    replays =
      Enum.count(state.trace, fn
        {_, :event, %{"type" => "user"}} -> true
        _ -> false
      end)

    IO.puts("\n" <> String.duplicate("=", 68))
    IO.puts("VERDICT: #{verdict}")
    IO.puts(String.duplicate("=", 68))
    IO.puts("  injected at:        #{state.injected_at || "-"}ms")
    IO.puts("  redirect tool at:   #{redirect_at || "-"}ms")
    IO.puts("  first result at:    #{first_result_at || "-"}ms")
    IO.puts("  result events:      #{state.results}")
    IO.puts("  user replay events: #{replays}")
    IO.puts("  files created:      #{Enum.join(present, ", ")}")
    IO.puts("  step3 skipped:      #{not File.exists?(Path.join(ws, "step3.txt"))}")

    turn2 =
      Enum.any?(state.trace, fn
        {_, :event, %{"type" => "assistant", "message" => %{"content" => blocks}}}
        when is_list(blocks) ->
          Enum.any?(
            blocks,
            &(is_map(&1) and &1["type"] == "text" and &1["text"] =~ "TURN-TWO-OK")
          )

        _ ->
          false
      end)

    IO.puts("  turn 2 same process: #{turn2}")
  end

  # Redacted: session ids, absolute paths, and cwd are stripped. This trace is
  # a protocol SHAPE record, not a transcript of the operator's account.
  defp write_trace(state) do
    dir = Path.join(["tmp", "probes"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "claude-duplex-#{state.inject_on}.jsonl")

    body =
      state.trace
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {at, kind, payload} ->
        Jason.encode!(%{"at_ms" => at, "kind" => kind, "payload" => redact(payload)})
      end)

    File.write!(path, body <> "\n")
    IO.puts("\ntrace: #{path}")
  end

  defp redact(%{} = map) do
    Map.new(map, fn
      {"session_id", _} -> {"session_id", "<redacted>"}
      {"uuid", _} -> {"uuid", "<redacted>"}
      {"cwd", _} -> {"cwd", "<redacted>"}
      {"apiKeySource", v} -> {"apiKeySource", v}
      {k, v} -> {k, redact(v)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  defp redact(str) when is_binary(str) do
    home = System.user_home!()
    String.replace(str, home, "~")
  end

  defp redact(other), do: other

  # --- misc ----------------------------------------------------------------

  defp now, do: System.monotonic_time(:millisecond)
  defp ms(state), do: now() - state.started

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("/bin/kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end

# Jason ships with the app but this script does not boot it — load the dep
# straight from _build so the probe stays a plain `elixir` invocation.
Enum.each(Path.wildcard("_build/dev/lib/*/ebin"), &Code.prepend_path/1)

{parsed, _rest, _invalid} =
  OptionParser.parse(System.argv(), strict: [inject_on: :string, keep: :boolean])

Probe.run(parsed)
