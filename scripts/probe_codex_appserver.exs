# CHAT_LIVE_STEERING_ROADMAP Phase 0, probes 3 and 4: does `codex app-server`
# give real mid-turn steering, does it reject a stale turn id, and does it
# confine a run the same way `codex exec -s read-only` does?
#
#   elixir scripts/probe_codex_appserver.exs --mode steer
#   elixir scripts/probe_codex_appserver.exs --mode confine
#
# Deliberately NOT `mix run`: no app boot, no dev DB. It drives the operator's
# real `codex`, so it is opt-in and never runs in CI.
#
# Protocol shapes were read from `codex app-server generate-json-schema --out`
# (codex-cli 0.146.0) rather than guessed:
#
#   thread/start   {cwd, sandbox: "read-only"|"workspace-write"|"danger-full-access", model?}
#                    -> {threadId}
#   turn/start     {threadId, input: [{type:"text", text}], clientUserMessageId?}
#                    -> {turn: {id, ...}}
#   turn/steer     {threadId, expectedTurnId, input, clientUserMessageId?}
#                    -> {turnId}
#   turn/interrupt {threadId, turnId}
#
# `SandboxMode` is the same three-value enum `AgentBackend.permission_args/2`
# already emits as `-s`, so the confinement translation is one-to-one.
#
# There are NO client notifications in the schema: `initialize` is a plain
# request/response and needs no `initialized` follow-up.

defmodule CodexProbe do
  def run(opts) do
    mode = Keyword.get(opts, :mode, "steer")
    keep? = Keyword.get(opts, :keep, false)

    workspace =
      Path.join(System.tmp_dir!(), "bc-probe-codex-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    binary =
      System.find_executable("codex") ||
        raise "codex is not on PATH — this probe needs the operator's real CLI"

    IO.puts("workspace: #{workspace}")
    IO.puts("binary:    #{binary}")
    IO.puts("mode:      #{mode}\n")

    port = open(binary, workspace)

    state = %{
      port: port,
      started: now(),
      buf: "",
      trace: [],
      next_id: 1,
      workspace: workspace,
      mode: mode
    }

    state =
      case mode do
        "steer" -> steer_probe(state)
        "confine" -> confine_probe(state)
        other -> raise "unknown --mode #{other} (steer | confine)"
      end

    write_trace(state)
    kill(port)
    unless keep?, do: File.rm_rf!(workspace)
    if keep?, do: IO.puts("\nworkspace kept: #{workspace}")
  end

  # --- probe 3: steering, stale rejection, interrupt -----------------------

  defp steer_probe(state) do
    {state, _init} =
      request(state, "initialize", %{
        "clientInfo" => %{
          "name" => "buster-claw-probe",
          "title" => "Buster Claw steering probe",
          "version" => "0.0.1"
        }
      })

    {state, thread} =
      request(state, "thread/start", %{
        "cwd" => state.workspace,
        "sandbox" => "workspace-write"
      })

    thread_id = thread["threadId"] || get_in(thread, ["thread", "id"])
    IO.puts("thread: #{short(thread_id)}\n")

    # `turn/start` returns as soon as the turn EXISTS — the work then streams as
    # notifications, so the turn id is available long before any of it happens.
    # That is what makes steering addressable.
    {state, started} =
      request(state, "turn/start", %{
        "threadId" => thread_id,
        "clientUserMessageId" => "probe-turn-1",
        "input" => [%{"type" => "text", "text" => task_prompt()}]
      })

    turn_id = get_in(started, ["turn", "id"]) || started["turnId"]
    IO.puts("\nturn 1: #{short(turn_id)}")

    # Steer from inside the notification stream, as soon as the first command
    # execution starts — the equivalent boundary to the Claude probe's tool
    # injection.
    state =
      drain_until_turn_completed(
        state,
        240_000,
        &steer_when_running(&1, &2, thread_id, turn_id)
      )

    # A stale expectedTurnId must be REJECTED, not silently applied to whatever
    # turn is current. This is the completion-race guard the roadmap's scenario
    # C depends on; if it did not error, Buster Claw would have to invent its
    # own guard.
    IO.puts("\n--- stale expectedTurnId rejection ---")

    {state, stale} =
      request(
        state,
        "turn/steer",
        %{
          "threadId" => thread_id,
          "expectedTurnId" => turn_id || "00000000-0000-0000-0000-000000000000",
          "input" => [%{"type" => "text", "text" => "This must not be accepted."}]
        },
        expect_error: true
      )

    report_steer(state, stale, turn_id)
  end

  # The steer itself, fired from inside the notification stream.
  defp steer_when_running(state, %{"method" => "item/started", "params" => params}, thread, turn) do
    item = params["item"] || %{}

    if not Map.get(state, :steered?, false) and command_item?(item) do
      IO.puts("--- first command execution started; steering now ---")

      {state, resp} =
        request(state, "turn/steer", %{
          "threadId" => thread,
          "expectedTurnId" => turn,
          "clientUserMessageId" => "probe-steer-1",
          "input" => [%{"type" => "text", "text" => steer_prompt()}]
        })

      IO.puts("--- turn/steer -> #{inspect(resp)} ---")

      # And immediately a WRONG expectedTurnId while this turn is still active.
      # The post-completion case (below) proves a finished turn rejects; this
      # proves the id is actually checked rather than the server just steering
      # whatever is current.
      {state, bogus} =
        request(
          state,
          "turn/steer",
          %{
            "threadId" => thread,
            "expectedTurnId" => "00000000-0000-0000-0000-000000000000",
            "input" => [%{"type" => "text", "text" => "This must not be accepted."}]
          },
          expect_error: true
        )

      IO.puts("--- bogus-id steer -> #{inspect(bogus["error"] || bogus)} ---")

      Map.merge(state, %{
        steered?: true,
        steer_at: ms(state),
        steer_response: resp,
        bogus_response: bogus
      })
    else
      state
    end
  end

  defp steer_when_running(state, _notification, _thread, _turn), do: state

  defp command_item?(%{"type" => "commandExecution"}), do: true
  defp command_item?(%{"commandExecution" => _}), do: true
  defp command_item?(%{"type" => "command_execution"}), do: true
  defp command_item?(_), do: false

  defp report_steer(state, stale, turn_id) do
    ws = state.workspace

    present =
      Enum.filter(
        ~w(step1.txt step2.txt step3.txt redirect.txt),
        &File.exists?(Path.join(ws, &1))
      )

    steered? = "redirect.txt" in present
    skipped? = "step3.txt" not in present

    completed_at =
      state.trace
      |> Enum.reverse()
      |> Enum.find_value(fn
        {at, :notification, %{"method" => "turn/completed"}} -> at
        _ -> nil
      end)

    redirect_at =
      state.trace
      |> Enum.reverse()
      |> Enum.find_value(fn
        {at, :notification, %{"method" => "item/" <> _} = n} ->
          if inspect(n) =~ "redirect.txt", do: at

        _ ->
          nil
      end)

    verdict =
      cond do
        not steered? ->
          "IGNORED — the steer never took effect"

        is_nil(completed_at) ->
          "INCONCLUSIVE — no turn/completed observed"

        redirect_at && redirect_at < completed_at ->
          "STEERED — redirect ran inside the ACTIVE turn"

        true ->
          "NEXT_TURN — redirect ran after the turn completed"
      end

    stale_rejected? = match?(%{"error" => _}, stale)

    IO.puts("\n" <> String.duplicate("=", 68))
    IO.puts("VERDICT: #{verdict}")
    IO.puts(String.duplicate("=", 68))
    IO.puts("  turn id:            #{short(turn_id)}")
    IO.puts("  steered at:         #{Map.get(state, :steer_at) || "-"}ms")
    IO.puts("  steer response:     #{inspect(Map.get(state, :steer_response))}")
    IO.puts("  redirect item at:   #{redirect_at || "-"}ms")
    IO.puts("  turn/completed at:  #{completed_at || "-"}ms")
    IO.puts("  files created:      #{Enum.join(present, ", ")}")
    IO.puts("  step3 skipped:      #{skipped?}")
    bogus = Map.get(state, :bogus_response) || %{}

    IO.puts(
      "  bogus id (active):  #{match?(%{"error" => e} when not is_nil(e), bogus)} #{inspect(bogus["error"])}"
    )

    IO.puts("  stale id (done):    #{stale_rejected?} #{inspect(stale["error"])}")

    state
  end

  # --- probe 4: confinement ------------------------------------------------
  #
  # App Server must not be a permission-widening back door. `-s read-only` on
  # `codex exec` refuses a write; `sandbox: "read-only"` on `thread/start` has
  # to refuse the same write, or replacing the chat path would quietly upgrade
  # every confined surface.

  defp confine_probe(state) do
    {state, _init} =
      request(state, "initialize", %{
        "clientInfo" => %{
          "name" => "buster-claw-probe",
          "title" => "Buster Claw confinement probe",
          "version" => "0.0.1"
        }
      })

    {state, thread} =
      request(state, "thread/start", %{
        "cwd" => state.workspace,
        "sandbox" => "read-only",
        "approvalPolicy" => "never"
      })

    thread_id = thread["threadId"] || get_in(thread, ["thread", "id"])
    IO.puts("thread: #{short(thread_id)} (sandbox=read-only, approvalPolicy=never)\n")

    {state, _started} =
      request(state, "turn/start", %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" =>
              "Using the shell, run exactly: echo escaped > escaped.txt\n" <>
                "Then tell me whether it succeeded."
          }
        ]
      })

    state = drain_until_turn_completed(state, 180_000)

    escaped? = File.exists?(Path.join(state.workspace, "escaped.txt"))

    IO.puts("\n" <> String.duplicate("=", 68))

    IO.puts(
      "VERDICT: #{if escaped?, do: "WIDENED — read-only sandbox allowed a WRITE", else: "CONFINED — the write was refused"}"
    )

    IO.puts(String.duplicate("=", 68))
    IO.puts("  escaped.txt exists: #{escaped?}")

    state
  end

  # --- JSON-RPC over the app-server port -----------------------------------

  defp open(binary, cwd) do
    cmd = ~s|exec perl -e 'setpgrp(0,0); exec @ARGV or exit 127' "$@"|
    shell_args = ["-lc", cmd, "sh", binary, "app-server"]

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :hide,
      {:args, shell_args},
      {:cd, String.to_charlist(cwd)}
    ])
  end

  # Send a request and pump the stream until its response arrives. Notifications
  # seen along the way are traced and, when `:on_notification` is given, may
  # themselves issue a nested request — which is exactly how the steer is fired
  # mid-turn.
  defp request(state, method, params, opts \\ []) do
    id = state.next_id
    state = %{state | next_id: id + 1}

    line =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    IO.puts(">>> [#{ms(state)}ms] #{method} (id=#{id})")
    Port.command(state.port, line <> "\n")

    state = %{
      state
      | trace: [{ms(state), :request, %{"method" => method, "id" => id}} | state.trace]
    }

    await(state, id, now() + Keyword.get(opts, :timeout, 240_000), opts)
  end

  defp await(state, id, deadline, opts) do
    remaining = max(deadline - now(), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        {lines, buf} = split_lines(state.buf <> data)
        {state, hit} = Enum.reduce(lines, {%{state | buf: buf}, nil}, &consume(&1, &2, id, opts))
        if hit, do: {state, hit}, else: await(state, id, deadline, opts)

      {port, {:exit_status, code}} when port == state.port ->
        IO.puts("!!! app-server EXITED status #{code}")
        {state, %{"error" => %{"message" => "app-server exited #{code}"}}}
    after
      remaining ->
        IO.puts("!!! [#{ms(state)}ms] timed out waiting for id=#{id}")
        {state, %{"error" => %{"message" => "timeout"}}}
    end
  end

  defp consume(line, {state, hit}, id, opts) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"id" => ^id} = msg} ->
        result = msg["result"] || %{"error" => msg["error"]}
        expect_error? = Keyword.get(opts, :expect_error, false)

        if msg["error"] && not expect_error? do
          IO.puts("<<< [#{ms(state)}ms] ERROR id=#{id}: #{inspect(msg["error"])}")
        else
          IO.puts("<<< [#{ms(state)}ms] response id=#{id}")
        end

        {%{state | trace: [{ms(state), :response, msg} | state.trace]}, result}

      {:ok, %{"method" => _} = notification} ->
        state = trace_notification(state, notification)

        state =
          case Keyword.get(opts, :on_notification) do
            fun when is_function(fun, 2) -> fun.(state, notification)
            _ -> state
          end

        {state, hit}

      {:ok, other} ->
        {%{state | trace: [{ms(state), :other, other} | state.trace]}, hit}

      _ ->
        case String.trim(line) do
          "" -> {state, hit}
          raw -> {%{state | trace: [{ms(state), :raw, %{"line" => raw}} | state.trace]}, hit}
        end
    end
  end

  # Pump notifications with no request outstanding, until the turn ends. `fun`
  # may itself issue a request (that is how the steer is fired mid-turn); its
  # nested receive consumes later bytes, which is safe because the lines already
  # split out of this batch no longer depend on the buffer.
  defp drain_until_turn_completed(state, budget, fun \\ nil) do
    do_drain(state, now() + budget, fun)
  end

  defp do_drain(state, deadline, fun) do
    remaining = max(deadline - now(), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        {lines, buf} = split_lines(state.buf <> data)

        {state, done} =
          Enum.reduce(lines, {%{state | buf: buf}, false}, &drain_line(&1, &2, fun))

        if done, do: state, else: do_drain(state, deadline, fun)

      {port, {:exit_status, code}} when port == state.port ->
        IO.puts("!!! app-server EXITED status #{code}")
        state
    after
      remaining ->
        IO.puts("!!! [#{ms(state)}ms] drain deadline reached")
        state
    end
  end

  defp drain_line(line, {state, done}, fun) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"method" => "turn/completed"} = n} ->
        {trace_notification(state, n), true}

      {:ok, %{"method" => _} = n} ->
        state = trace_notification(state, n)
        state = if is_function(fun, 2), do: fun.(state, n), else: state
        {state, done}

      {:ok, other} ->
        {%{state | trace: [{ms(state), :other, other} | state.trace]}, done}

      _ ->
        {state, done}
    end
  end

  defp trace_notification(state, %{"method" => method} = n) do
    at = ms(state)
    unless noisy?(method), do: IO.puts("<<< [#{at}ms] #{describe(n)}")
    %{state | trace: [{at, :notification, n} | state.trace]}
  end

  # Deltas are the bulk of the stream and say nothing about steering. They are
  # still traced — just not printed.
  defp noisy?(m),
    do:
      String.ends_with?(m, "/delta") or String.contains?(m, "Delta") or
        m in ["thread/tokenUsage/updated"]

  defp describe(%{"method" => "item/started", "params" => p}),
    do: "item/started #{item_brief(p["item"])}"

  defp describe(%{"method" => "item/completed", "params" => p}),
    do: "item/completed #{item_brief(p["item"])}"

  defp describe(%{"method" => "turn/completed", "params" => p}),
    do: "TURN/COMPLETED #{inspect(Map.take(p, ["turnId", "usage", "status"]))}"

  defp describe(%{"method" => m, "params" => p}) when is_map(p),
    do: "#{m} #{inspect(Map.take(p, ["turnId", "threadId", "status"]))}"

  defp describe(%{"method" => m}), do: m

  defp item_brief(%{"type" => t} = item) do
    detail =
      cond do
        is_binary(item["command"]) ->
          one_line(String.slice(item["command"], 0, 60))

        is_list(item["command"]) ->
          one_line(Enum.join(item["command"], " ") |> String.slice(0, 60))

        is_binary(item["text"]) ->
          one_line(String.slice(item["text"], 0, 60))

        true ->
          ""
      end

    "#{t}(#{detail})"
  end

  defp item_brief(other), do: inspect(other) |> String.slice(0, 80)

  # --- prompts -------------------------------------------------------------

  defp task_prompt do
    """
    Do exactly these three steps in order, each as its own separate shell \
    command, and say one short sentence before each one:

    1. sleep 8 && echo step-one > step1.txt
    2. sleep 8 && echo step-two > step2.txt
    3. sleep 8 && echo step-three > step3.txt

    Do not combine them into one command. Do not run them in the background.
    """
  end

  defp steer_prompt do
    """
    CHANGE OF PLAN: stop the three-step sequence immediately. Do not run any \
    remaining steps. Instead run this single shell command and then finish:

    echo redirected > redirect.txt
    """
  end

  # --- misc ----------------------------------------------------------------

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end

  defp write_trace(state) do
    dir = Path.join(["tmp", "probes"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "codex-appserver-#{state.mode}.jsonl")

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
      {"threadId", _} -> {"threadId", "<redacted>"}
      {"turnId", _} -> {"turnId", "<redacted>"}
      {"cwd", _} -> {"cwd", "<redacted>"}
      {k, v} -> {k, redact(v)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(str) when is_binary(str), do: String.replace(str, System.user_home!(), "~")
  defp redact(other), do: other

  defp one_line(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()
  defp short(nil), do: "-"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(other), do: inspect(other)

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

Enum.each(Path.wildcard("_build/dev/lib/*/ebin"), &Code.prepend_path/1)

{parsed, _rest, _invalid} =
  OptionParser.parse(System.argv(), strict: [mode: :string, keep: :boolean])

CodexProbe.run(parsed)
