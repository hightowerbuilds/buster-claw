# CHAT_LIVE_STEERING_ROADMAP Phase 0, probes 5 and 6: does `opencode serve`
# accept a prompt INTO a busy session's active run, and can the server API be
# trusted to report the fail-open agent fallback?
#
#   elixir scripts/probe_opencode_server.exs --mode steer
#   elixir scripts/probe_opencode_server.exs --mode confine
#
# Deliberately NOT `mix run`: no app boot, no dev DB. Drives the operator's real
# `opencode`, so it is opt-in and never runs in CI.
#
# Shapes read from the server's own OpenAPI document (`GET /doc`) on
# opencode 1.18.3, not from the public docs page.
#
# ⚠ TWO API generations are live, and the probe uses BOTH — on purpose.
#
#   v2  POST /api/session/{id}/prompt   {prompt:{text}, delivery:"steer"|"queue"}
#                                         -> {data: SessionInputAdmitted}
#       Perfect vocabulary, and it DOES NOT RUN: a v2 session parks the prompt in
#       a `session.next.*` buffer and stays at cost 0 forever. It evidently wants
#       a separate driver (the TUI / the bundled web app at `/app`).
#
#   v1  POST /session/{id}/prompt_async {model:{providerID,modelID}, parts:[…]}
#                                         -> EMPTY BODY, no receipt at all
#       The only path that executes from a plain HTTP client, so it is the one
#       whose steering behaviour is worth measuring — `--mode steer` uses it.
#
# `--mode confine` stays on v2 because session creation is where an agent name
# would be validated, and v2 is the generation that models it explicitly.
#
# Auth: Basic, and the username is literally `opencode` — an empty username is
# rejected. The password comes from OPENCODE_SERVER_PASSWORD in the environment,
# never argv (it would otherwise be visible in `ps`).

defmodule OpenCodeProbe do
  @user "opencode"

  def run(opts) do
    mode = Keyword.get(opts, :mode, "steer")
    model = Keyword.get(opts, :model, "opencode-go/glm-5.2")
    port_no = Keyword.get(opts, :port, 4751)
    keep? = Keyword.get(opts, :keep, false)

    workspace =
      Path.join(System.tmp_dir!(), "bc-probe-opencode-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    binary =
      System.find_executable("opencode") ||
        raise "opencode is not on PATH — this probe needs the operator's real CLI"

    password = "probe-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    IO.puts("workspace: #{workspace}")
    IO.puts("binary:    #{binary}")
    IO.puts("mode:      #{mode}")
    IO.puts("model:     #{model}")
    IO.puts("port:      #{port_no}\n")

    server = start_server(binary, workspace, port_no, password)

    state = %{
      started: now(),
      base: "http://127.0.0.1:#{port_no}",
      password: password,
      workspace: workspace,
      model: model,
      mode: mode,
      trace: [],
      server: server
    }

    state = await_health(state, now() + 60_000)

    state =
      case mode do
        "steer" -> steer_probe(state)
        "confine" -> confine_probe(state)
        other -> raise "unknown --mode #{other} (steer | confine)"
      end

    write_trace(state)
    stop_server(server)
    unless keep?, do: File.rm_rf!(workspace)
    if keep?, do: IO.puts("\nworkspace kept: #{workspace}")
  end

  # --- probe 5: busy-session steering --------------------------------------

  # ⚠ This uses the **v1** API, not v2, and that is a measured decision:
  # a v2 session admits a prompt into a `session.next.*` buffer and then never
  # runs it — cost stays 0, no messages are produced. v2 evidently expects a
  # separate driver (the TUI / bundled web app). v1 `prompt_async` is the only
  # path that actually executes from a plain HTTP client, so it is the only one
  # whose steering behaviour is worth measuring.
  #
  # v1 has no `delivery` field and returns an EMPTY body — no admission receipt
  # at all. That is precisely the case the roadmap warned about: there is nothing
  # to show as "accepted" except our own optimism.
  defp steer_probe(state) do
    {state, session} = post(state, "/session", %{"title" => "buster-claw steering probe"})

    session_id = session["id"] || get_in(session, ["data", "id"])
    unless session_id, do: raise("session create failed: #{inspect(session)}")
    IO.puts("session: #{session_id} (v1)\n")

    sse = open_sse(state)

    {state, admit1} = prompt_async(state, session_id, task_prompt())
    IO.puts("turn 1 submitted: #{inspect(admit1)}\n")

    # Steer once a shell command is genuinely RUNNING. The earlier version of
    # this probe matched "sleep 8" anywhere in the stream and fired on the
    # server's echo of our own prompt — before any work had started. The tool
    # part is the real boundary.
    state =
      watch(state, sse, 300_000, fn state, raw ->
        if not Map.get(state, :steered?, false) and tool_running?(raw) do
          IO.puts("\n--- first command RUNNING; steering now ---")
          {state, admit2} = prompt_async(state, session_id, steer_prompt())
          IO.puts("--- steer submitted: #{inspect(admit2)} ---\n")
          Map.merge(state, %{steered?: true, steer_at: ms(state), steer_receipt: admit2})
        else
          state
        end
      end)

    close_sse(sse)
    report_steer(state)
  end

  # A tool part carrying the step-1 command, as opposed to the prompt text that
  # merely quotes it. Both contain "sleep 8"; only the tool event names a tool.
  defp tool_running?(raw) do
    String.contains?(raw, "sleep 8") and String.contains?(raw, "\"tool\"") and
      not String.contains?(raw, "Do exactly these three steps")
  end

  defp prompt_async(state, session_id, text) do
    [provider, model_id] =
      case String.split(state.model, "/", parts: 2) do
        [p, m] -> [p, m]
        [m] -> ["opencode", m]
      end

    post(state, "/session/#{session_id}/prompt_async", %{
      "model" => %{"providerID" => provider, "modelID" => model_id},
      "parts" => [%{"type" => "text", "text" => text}]
    })
  end

  defp report_steer(state) do
    ws = state.workspace

    present =
      Enum.filter(
        ~w(step1.txt step2.txt step3.txt redirect.txt),
        &File.exists?(Path.join(ws, &1))
      )

    steered? = "redirect.txt" in present
    skipped? = "step3.txt" not in present

    verdict =
      cond do
        not steered? -> "IGNORED — the steered message never took effect"
        skipped? -> "STEERED — redirect ran and the remaining steps were abandoned"
        true -> "NEXT_TURN — redirect ran, but only after the original run finished"
      end

    IO.puts("\n" <> String.duplicate("=", 68))
    IO.puts("VERDICT: #{verdict}")
    IO.puts(String.duplicate("=", 68))
    IO.puts("  steered at:          #{Map.get(state, :steer_at) || "-"}ms")
    IO.puts("  receipt:             #{inspect(Map.get(state, :steer_receipt))}")
    IO.puts("  files created:       #{Enum.join(present, ", ")}")
    IO.puts("  step3 skipped:       #{skipped?}")
    IO.puts("  redirect ran:        #{steered?}")

    state
  end

  # --- probe 6: is the fail-open fallback detectable? ----------------------
  #
  # `opencode run --agent missing` prints a warning to stderr, runs UNCONFINED
  # under the default `build` agent, and exits 0 — which is why
  # `AgentBackend.fallback_warning?/2` exists. In server mode there is no stderr
  # to scrape, so the question is whether the API states the truth instead.

  defp confine_probe(state) do
    bogus = "definitely-not-a-real-agent-#{System.unique_integer([:positive])}"

    {state, resp} =
      post(state, "/api/session", %{
        "model" => model_ref(state.model),
        "agent" => bogus,
        "location" => %{"directory" => state.workspace}
      })

    IO.puts("\ncreate-with-bogus-agent response:\n#{inspect(resp, pretty: true, limit: 12)}\n")

    session_id = get_in(resp, ["data", "id"])
    reported = get_in(resp, ["data", "agent"])

    {state, fetched} =
      if session_id, do: get(state, "/api/session/#{session_id}"), else: {state, %{}}

    refetched = get_in(fetched, ["data", "agent"])

    rejected? = is_nil(session_id)

    # A session that merely ECHOES the agent name back has told us nothing. The
    # security question is whether the RUN proceeds. Send a trivial prompt and
    # see whether the server refuses it or happily starts work under whatever
    # agent it actually resolved.
    {state, ran?, prompt_resp} =
      if session_id do
        {state, resp} =
          post(state, "/api/session/#{session_id}/prompt", %{
            "prompt" => %{"text" => "Reply with exactly: OK"},
            "delivery" => "queue"
          })

        {state, is_map(resp["data"]), resp}
      else
        {state, false, %{}}
      end

    detectable? =
      rejected? or
        (is_binary(reported) and reported != bogus) or
        (is_binary(refetched) and refetched != bogus) or
        not ran?

    IO.puts("\n" <> String.duplicate("=", 68))

    IO.puts(
      "VERDICT: #{if detectable?, do: "DETECTABLE — the API does not pretend", else: "FAILS OPEN SILENTLY — no trustworthy signal"}"
    )

    IO.puts(String.duplicate("=", 68))
    IO.puts("  requested agent:     #{bogus}")
    IO.puts("  create rejected:     #{rejected?}")
    IO.puts("  agent in create:     #{inspect(reported)}")
    IO.puts("  agent on re-fetch:   #{inspect(refetched)}")
    IO.puts("  prompt admitted:     #{ran?} #{inspect(receipt(prompt_resp))}")

    state
  end

  # --- server lifecycle ----------------------------------------------------

  defp start_server(binary, cwd, port_no, password) do
    cmd = ~s|exec perl -e 'setpgrp(0,0); exec @ARGV or exit 127' "$@" 2>&1|

    shell_args = [
      "-lc",
      cmd,
      "sh",
      binary,
      "serve",
      "--port",
      Integer.to_string(port_no),
      "--hostname",
      "127.0.0.1"
    ]

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :hide,
      {:args, shell_args},
      {:cd, String.to_charlist(cwd)},
      {:env, [{~c"OPENCODE_SERVER_PASSWORD", String.to_charlist(password)}]}
    ])
  end

  defp stop_server(port) do
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

  defp await_health(state, deadline) do
    {out, code} =
      System.cmd(
        "curl",
        [
          "-s",
          "-o",
          "/dev/null",
          "-w",
          "%{http_code}",
          "-m",
          "3",
          "-u",
          auth(state),
          state.base <> "/api/session"
        ],
        stderr_to_stdout: true
      )

    cond do
      code == 0 and String.trim(out) == "200" ->
        IO.puts("server healthy after #{ms(state)}ms\n")
        state

      now() > deadline ->
        raise "opencode server never became healthy (last: #{out})"

      true ->
        drain_server_output()
        Process.sleep(500)
        await_health(state, deadline)
    end
  end

  # Keep the server's own stdout from filling the port's message queue.
  defp drain_server_output do
    receive do
      {_port, {:data, _}} -> drain_server_output()
    after
      0 -> :ok
    end
  end

  # --- SSE -----------------------------------------------------------------

  defp open_sse(state) do
    Port.open({:spawn_executable, "/usr/bin/curl"}, [
      :binary,
      :exit_status,
      :hide,
      {:args, ["-sN", "-u", auth(state), state.base <> "/event"]}
    ])
  end

  defp close_sse(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # Pump the SSE stream until the session goes idle (after we have steered), or
  # the budget runs out. `fun` sees each raw event payload.
  defp watch(state, sse, budget, fun) do
    do_watch(state, sse, now() + budget, fun, "")
  end

  defp do_watch(state, sse, deadline, fun, buf) do
    remaining = max(deadline - now(), 0)

    receive do
      {^sse, {:data, data}} ->
        {lines, buf} = split_lines(buf <> data)
        {state, idle?} = Enum.reduce(lines, {state, false}, &sse_line(&1, &2, fun))

        if idle? and Map.get(state, :steered?, false),
          do: state,
          else: do_watch(state, sse, deadline, fun, buf)

      {^sse, {:exit_status, code}} ->
        IO.puts("!!! SSE stream ended (#{code})")
        state
    after
      remaining ->
        IO.puts("!!! [#{ms(state)}ms] watch deadline reached")
        state
    end
  end

  defp sse_line("data: " <> payload, {state, idle?}, fun) do
    raw = String.trim(payload)
    state = %{state | trace: [{ms(state), :event, raw} | state.trace]}

    state =
      case Jason.decode(raw) do
        {:ok, %{"type" => type} = ev} ->
          unless noisy?(type), do: IO.puts("<<< [#{ms(state)}ms] #{describe(type, ev)}")
          state

        _ ->
          state
      end

    # `session.idle` is v1's settle signal — the run is over and, crucially, the
    # steered message has either landed in it or missed it.
    {fun.(state, raw), idle? or String.contains?(raw, "session.idle")}
  end

  defp sse_line(_line, acc, _fun), do: acc

  defp noisy?(type),
    do: String.contains?(type, "delta") or type in ["server.connected", "storage.write"]

  defp describe(type, ev) do
    props = ev["properties"] || ev["data"] || %{}
    brief = props |> inspect(limit: 4) |> String.slice(0, 120)
    "#{type} #{brief}"
  end

  # --- HTTP ----------------------------------------------------------------

  defp post(state, path, body) do
    json = Jason.encode!(body)

    args = [
      "-s",
      "-m",
      "60",
      "-u",
      auth(state),
      "-H",
      "content-type: application/json",
      "-X",
      "POST",
      "--data-binary",
      json,
      state.base <> path
    ]

    run_curl(state, "POST " <> path, args)
  end

  defp get(state, path) do
    run_curl(state, "GET " <> path, ["-s", "-m", "30", "-u", auth(state), state.base <> path])
  end

  defp run_curl(state, label, args) do
    IO.puts(">>> [#{ms(state)}ms] #{label}")
    {out, _code} = System.cmd("curl", args, stderr_to_stdout: true)

    decoded =
      case Jason.decode(out) do
        {:ok, map} -> map
        _ -> %{"raw" => String.slice(out, 0, 400)}
      end

    {%{
       state
       | trace: [{ms(state), :http, %{"label" => label, "response" => decoded}} | state.trace]
     }, decoded}
  end

  defp auth(state), do: @user <> ":" <> state.password

  defp receipt(%{"data" => data}) when is_map(data),
    do: Map.take(data, ["delivery", "admittedSeq", "promotedSeq", "id"])

  defp receipt(other), do: other

  defp model_ref(model) do
    case String.split(model, "/", parts: 2) do
      [provider, id] -> %{"providerID" => provider, "id" => id}
      [id] -> %{"providerID" => "opencode", "id" => id}
    end
  end

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
    path = Path.join(dir, "opencode-server-#{state.mode}.jsonl")

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
      {"sessionID", _} -> {"sessionID", "<redacted>"}
      {"directory", _} -> {"directory", "<redacted>"}
      {k, v} -> {k, redact(v)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  defp redact(str) when is_binary(str) do
    str
    |> String.replace(System.user_home!(), "~")
    |> String.replace(~r/ses_[A-Za-z0-9]+/, "ses_<redacted>")
  end

  defp redact(other), do: other

  defp now, do: System.monotonic_time(:millisecond)
  defp ms(state), do: now() - state.started
end

Enum.each(Path.wildcard("_build/dev/lib/*/ebin"), &Code.prepend_path/1)

{parsed, _rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [mode: :string, model: :string, port: :integer, keep: :boolean]
  )

OpenCodeProbe.run(parsed)
