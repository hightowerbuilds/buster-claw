defmodule BusterClaw.AgentRunner do
  @moduledoc """
  Phase 0 of the always-on (unattended shift) roadmap: a one-shot, headless run
  of the user's own agent CLI (`claude` / `codex`), spawned non-interactively
  from the BEAM so an unattended shift can work the Dispatch queue without a
  human in a terminal.

  This module is intentionally *generic*: it runs a given prompt and returns the
  agent's output. Building the "work the Dispatch queue for job X" prompt is the
  caller's job (the Phase 1 dispatcher), so the launch primitive stays small and
  testable.

  ## Design

  - The agent is spawned via a Port through `/bin/sh -c 'exec "$@" 2>&1'`, which
    (a) merges stderr into stdout for a single captured stream and (b) passes the
    binary + args through `"$@"` with **no shell-escaping of the prompt** — the
    prompt is a discrete `args` element, never interpolated into a command string.
    Stdin is attached to `/dev/null`: prompts are positional arguments and this
    runner never streams input to the child. An explicit EOF also prevents recent
    Claude Code releases from waiting three seconds for nonexistent piped context.
  - The spawned process inherits the BEAM's environment (HOME/PATH), which is how
    it reaches the agent's *persisted* login — headless auth needs no TTY. Tests
    override `:agent_binary`/`:argv`/`:env` to stay hermetic.
  - A wall-clock deadline kills a hung run (the `exec` means the captured os_pid
    *is* the agent, so the kill lands on it). The run is launched as its own
    process-group leader (`setpgrp` before the final `exec`), so a timeout kills
    the whole group — the agent AND the tool subprocesses (Bash/MCP) it spawned —
    instead of leaking grandchildren behind the reaped parent.

  ## Trust boundary (important)

  Most callers run `claude` with `--permission-mode bypassPermissions` so it does
  not stall on its own permission prompts in headless mode. That is **not** what
  authorizes the agent's actions — `BusterClaw.Commands` (the `:trusted` tier +
  the provenance gate on outbound/irreversible commands) is the usual
  authorization boundary.

  Callers that expose tools outside `BusterClaw.Commands` must choose a stricter
  mode explicitly. The Trading surface, for example, uses `dontAsk` plus an
  allowlist containing only Robinhood's read tools. An unlisted write tool is
  denied by the agent process before the model can invoke it.
  """

  require Logger

  alias BusterClaw.AgentBackend
  alias BusterClaw.Library.Artifact

  # 10-minute default wall-clock cap. The Phase 2 governor will set this per-run
  # from the shift budget; this is just a safe ceiling for a lone call.
  @default_timeout_ms 10 * 60 * 1000

  @canonical_claude Path.expand("~/.local/bin/claude")

  @type run_result :: %{
          agent: atom(),
          binary: String.t(),
          exit_status: integer(),
          output: String.t(),
          duration_ms: non_neg_integer()
        }

  @doc """
  Run `prompt` through the resolved agent and return its captured output.

  Returns `{:ok, run_result}` on a clean exit (any exit status — a non-zero
  status is reported, not treated as a crash), or `{:error, reason}` where reason
  is `:no_agent_cli`, `{:timeout, partial}`, or `{:unconfined, run_result}` — the
  last when the backend silently discarded the confinement we asked for (see
  `AgentBackend.fallback_warning?/2`; only opencode can do this).

  ## Options

    * `:agent` / `:agent_binary` — override detection (mostly for tests).
    * `:argv` — fully override the agent's argument vector (tests).
    * `:model` — the model ID, translated per backend by `AgentBackend.argv/3`.
      Unset omits the flag entirely, leaving the CLI's own default in charge.
    * `:cwd` — working directory (default: the workspace root).
    * `:timeout_ms` — wall-clock cap (default: #{@default_timeout_ms}).
    * `:env` — extra `{name, value}` string pairs layered on the inherited env.
    * `:shell` — shell to spawn through (default `/bin/sh`).
    * `:login` — run the shell as a login shell so it sources the user's profile
      (PATH/auth). Default `false`; the Dispatcher sets it for real runs.
    * `:permission_mode` — Claude's permission-mode vocabulary (default
      `"bypassPermissions"`), translated to each other backend's equivalent by
      `AgentBackend.permission_args/2`. Use `"dontAsk"` with an explicit
      `--allowedTools` list for a deny-by-default tool surface.
  """
  @spec run(String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, {agent, binary}} <- resolve_agent(opts) do
      cwd = Keyword.get(opts, :cwd) || Artifact.workspace_root()
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      args = build_args(agent, prompt, opts)
      exec(agent, binary, args, cwd, opts, timeout)
    end
  end

  @doc """
  Resolve which agent CLI to use, `{:ok, {agent, binary_path}}` or
  `{:error, :no_agent_cli}`. Exposed so the Phase 1 dispatcher can refuse to go
  unattended (with a clear message) when no agent is installed.

  Test seam: the `:agent_cli` app env forces the result — `{agent, path}` for
  present, `:none` for absent — so UI tests don't depend on whether the host
  machine happens to have `claude` on PATH (CI runners don't).
  """
  @spec detect() :: {:ok, {atom(), String.t()}} | {:error, :no_agent_cli}
  def detect do
    case Application.get_env(:buster_claw, :agent_cli) do
      {agent, path} when is_atom(agent) and is_binary(path) ->
        {:ok, {agent, path}}

      :none ->
        {:error, :no_agent_cli}

      _ ->
        detect_on_path()
    end
  end

  # `AgentBackend.order/0` IS this fallback order, so adding a harness is a
  # one-line change there rather than another `cond` clause here. opencode is
  # last on purpose: a machine that already had claude or codex must resolve to
  # the same backend it did before opencode was supported.
  defp detect_on_path do
    Enum.find_value(AgentBackend.order(), {:error, :no_agent_cli}, fn backend ->
      case backend_path(backend) do
        path when is_binary(path) -> {:ok, {backend, path}}
        _ -> nil
      end
    end)
  end

  defp backend_path(:claude), do: claude_path()

  # An unrecognised backend has no executable name at all. Returning nil lets the
  # caller answer `{:error, {:agent_unavailable, backend}}`; passing nil to
  # `System.find_executable/1` would raise a FunctionClauseError instead.
  defp backend_path(backend) do
    case AgentBackend.executable(backend) do
      name when is_binary(name) -> System.find_executable(name)
      _ -> nil
    end
  end

  # Three ways to land on a harness, most explicit first:
  #
  #   1. `:agent_binary` — an exact path (tests, or an unusual install).
  #   2. `:agent` alone — a NAMED backend, resolved to its executable. This is
  #      what `ModelPolicy.backend_for/1` returns, and before 08-03 passing it
  #      without a binary did nothing at all: the name was read only as a label
  #      for an explicit path. A chosen backend that silently ran a different one
  #      is the worst outcome available here, so an installed-check failure is a
  #      hard error rather than a fall-through to detection.
  #   3. Neither — `detect/0` walks PATH, exactly as it always has.
  defp resolve_agent(opts) do
    case {Keyword.get(opts, :agent_binary), Keyword.get(opts, :agent)} do
      {path, agent} when is_binary(path) -> {:ok, {agent || :custom, path}}
      {_, nil} -> detect()
      {_, agent} -> resolve_named_agent(agent)
    end
  end

  defp resolve_named_agent(agent) do
    case backend_path(agent) do
      path when is_binary(path) -> {:ok, {agent, path}}
      _ -> {:error, {:agent_unavailable, agent}}
    end
  end

  defp claude_path do
    System.find_executable("claude") || (File.exists?(@canonical_claude) && @canonical_claude) ||
      nil
  end

  @doc """
  Open a **streaming** Port running the agent, non-blocking. The caller owns the
  receive loop (`{port, {:data, _}}` / `{port, {:exit_status, _}}`) and any
  wall-clock deadline; this is the variant the chat backend uses to broadcast
  events as they arrive. `run/2` is the blocking, collect-everything variant.

  Streaming-specific agent flags (e.g. `--output-format stream-json`,
  `--resume <id>`) go in `:extra_args`. Same `:cwd`/`:login`/`:env`/`:shell`
  options as `run/2`.

  Returns `{:ok, %{port: port, agent: agent, binary: binary}}` or
  `{:error, :no_agent_cli}`.

  **Unlike `run/2`, this cannot refuse an unconfined run for you.** The output is
  the caller's, so a streaming caller that named an `:agent` must run its own
  accumulated output past `AgentBackend.fallback_warning?/2` and abandon the run
  if it fires — opencode exits 0 after silently dropping the confinement, so the
  exit status will look clean.
  """
  @spec open(String.t(), keyword()) ::
          {:ok, %{port: port(), agent: atom(), binary: String.t()}} | {:error, term()}
  def open(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, {agent, binary}} <- resolve_agent(opts) do
      cwd = Keyword.get(opts, :cwd) || Artifact.workspace_root()
      args = build_args(agent, prompt, opts)
      port = open_port(binary, args, cwd, opts)
      {:ok, %{port: port, agent: agent, binary: binary}}
    end
  rescue
    error ->
      Logger.error("AgentRunner failed to open stream: #{Exception.message(error)}")
      {:error, {:spawn_failed, Exception.message(error)}}
  end

  # `:argv` is an explicit escape hatch (tests, or unusual agents). Otherwise the
  # known agents get their documented non-interactive invocation, with any
  # `:extra_args` (streaming flags, --resume) appended.
  defp build_args(agent, prompt, opts) do
    case Keyword.get(opts, :argv) do
      argv when is_list(argv) -> argv
      _ -> default_args(agent, prompt, opts) ++ Keyword.get(opts, :extra_args, [])
    end
  end

  # Each harness's non-interactive invocation lives in `AgentBackend` — the flag
  # vocabulary differs per CLI (model, sandbox/permission, streaming) and the
  # table there was measured from `--help` rather than recalled. The claude shape
  # is unchanged by that move; codex gained the flags it always supported and
  # never received.
  defp default_args(agent, prompt, opts), do: AgentBackend.argv(agent, prompt, opts)

  defp exec(agent, binary, args, cwd, opts, timeout) do
    start = now_ms()
    port = open_port(binary, args, cwd, opts)

    port
    |> collect("", start + timeout, agent, binary, start)
    |> refuse_unconfined(agent)
  rescue
    error ->
      Logger.error("AgentRunner failed to spawn #{agent}: #{Exception.message(error)}")
      {:error, {:spawn_failed, Exception.message(error)}}
  end

  # `<shell> -c '…perl… exec @ARGV… </dev/null 2>&1' sh <binary> <args...>` —
  # `$@` starts after the `sh` placeholder (arg0), so the binary and prompt pass
  # through untouched and stderr is merged into stdout. Stdin is explicitly EOF:
  # AgentRunner has no stdin API, and Claude Code 2.1.220 otherwise waits three
  # seconds for piped context before warning and proceeding.
  #
  # We `exec perl -e 'setpgrp(0,0); exec @ARGV'` so the run becomes its own
  # process-group leader (pgid == os_pid, preserved across the final `exec` into
  # the agent) — this is what lets `kill_port/1` reap the whole group (agent +
  # its Bash/MCP tool subprocesses) on a timeout instead of orphaning them. `perl`
  # is universally present on macOS and, unlike `setsid`, needs no extra binary.
  #
  # `:login` runs the shell as a login shell (`-lc`) so it sources the user's
  # profile (~/.zprofile etc.) — the same trick `terminal.rs` uses, so a
  # daemon-spawned run reaches the same PATH/auth a human-launched terminal agent
  # does (critical in the packaged `.app`, whose env is otherwise bare). Defaults
  # stay `/bin/sh -c` so tests are hermetic.
  defp open_port(binary, args, cwd, opts) do
    shell = Keyword.get(opts, :shell) || "/bin/sh"
    flag = if Keyword.get(opts, :login, false), do: "-lc", else: "-c"
    cmd = ~s|exec perl -e 'setpgrp(0,0); exec @ARGV or exit 127' "$@" </dev/null 2>&1|
    shell_args = [flag, cmd, "sh", binary | args]

    port_opts =
      [:binary, :exit_status, :hide, {:args, shell_args}, {:cd, String.to_charlist(cwd)}] ++
        env_opt(opts)

    Port.open({:spawn_executable, shell}, port_opts)
  end

  defp env_opt(opts) do
    case Keyword.get(opts, :env) do
      pairs when is_list(pairs) and pairs != [] ->
        [{:env, Enum.map(pairs, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}]

      _ ->
        []
    end
  end

  defp collect(port, acc, deadline, agent, binary, start) do
    remaining = max(deadline - now_ms(), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, acc <> data, deadline, agent, binary, start)

      {^port, {:exit_status, status}} ->
        {:ok,
         %{
           agent: agent,
           binary: binary,
           exit_status: status,
           output: acc,
           duration_ms: now_ms() - start
         }}
    after
      remaining ->
        kill_port(port)
        Logger.warning("AgentRunner timed out #{agent} after #{now_ms() - start}ms; killed")
        {:error, {:timeout, %{agent: agent, output: acc, duration_ms: now_ms() - start}}}
    end
  end

  # opencode does not fail when `--agent` names a file it cannot find: it prints
  # a line on stderr, falls back to its default `build` agent — whose permission
  # is `{"*", allow, "*"}` — and exits 0. So a caller that checked only the exit
  # status would accept a completely unconfined run as a clean one.
  #
  # The warning can only appear when we named an agent, which we only do to
  # confine the run. Its presence therefore means the confinement we asked for
  # was silently discarded, and that is a failed run, not a warning. The output
  # rides along so a caller can still show what happened.
  defp refuse_unconfined({:ok, %{output: output} = result}, agent) do
    if AgentBackend.fallback_warning?(agent, output) do
      Logger.error(
        "AgentRunner: #{agent} ignored --agent and ran unconfined; refusing the result"
      )

      {:error, {:unconfined, result}}
    else
      {:ok, result}
    end
  end

  defp refuse_unconfined(other, _agent), do: other

  @doc """
  Kill the underlying OS process group (the run is its own group leader via
  `setpgrp`, so pgid == os_pid) then close the port. Signalling the negative
  pgid reaps the agent AND the Bash/MCP tool subprocesses it spawned, so a
  timeout doesn't leak grandchildren. Best-effort: a run that finished a
  microsecond before the deadline may have no os_pid left, which is fine.
  Exposed for streaming callers (`open/2`) that own their own deadline.
  """
  def kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        # Kill the whole group (pgid == os_pid), then the leader directly as a
        # belt-and-suspenders in case the group signal missed it (e.g. `setpgrp`
        # was unavailable and the process never became a leader). The `--` is
        # load-bearing on Linux: procps kill parses a bare `-123` as an option
        # and silently fails (BSD/macOS kill tolerates it), leaking the group.
        System.cmd("/bin/kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

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

  defp now_ms, do: System.monotonic_time(:millisecond)
end
