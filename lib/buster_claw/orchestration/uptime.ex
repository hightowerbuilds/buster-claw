defmodule BusterClaw.Orchestration.Uptime do
  @moduledoc """
  Shift-scoped OS uptime: keeps the Mac awake and the app relaunchable **only
  while an orchestration shift is active**.

  A passive listener on the `"orchestration"` PubSub topic (mirrors
  `BusterClaw.Orchestration.Reporter`). On `:shift_started` it **engages** —
  spawns `caffeinate -dimsu` (no display/idle/disk/system sleep) and, if the
  launchd KeepAlive agent is installed, `launchctl load`s it so a force-quit gets
  relaunched. On `:shift_stopped` / `:shift_completed` it **releases** — kills
  caffeinate and `launchctl unload`s the agent, so the machine can sleep and the
  app stays mortal when idle.

  Resilience: if the app boots with a shift already active (e.g. launchd
  relaunched it mid-shift), `init` engages immediately.

  Every OS action goes through an injectable `:ops` map (default: the real macOS
  implementations) and is wrapped so a failure never crashes the process or
  wedges the shift. The defaults are no-ops off macOS, and the launchd steps are
  no-ops when the agent plist isn't installed (e.g. in dev / unpackaged).
  """

  use GenServer

  require Logger

  alias BusterClaw.Orchestration

  @launchd_label "com.hightowerbuilds.busterclaw"
  @caffeinate_args ["-dimsu"]

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Orchestration.subscribe()
    state = %{ops: Keyword.get(opts, :ops, default_ops()), caffeinate: nil}

    # If a shift is already active (app relaunched mid-shift), re-assert uptime.
    state = if Orchestration.shift_active?(), do: engage(state), else: state
    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:orchestration, :shift_started}, state), do: {:noreply, engage(state)}

  def handle_info({:orchestration, event}, state)
      when event in [:shift_stopped, :shift_completed],
      do: {:noreply, release(state)}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    release(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Engage / release
  # ---------------------------------------------------------------------------

  # Already engaged — don't spawn a second caffeinate.
  defp engage(%{caffeinate: handle} = state) when not is_nil(handle), do: state

  defp engage(%{ops: ops} = state) do
    handle = safe(fn -> ops.start_caffeinate.() end, nil, "start caffeinate")
    safe(fn -> ops.launchd_load.() end, :ok, "launchd load")
    %{state | caffeinate: handle}
  end

  defp release(%{ops: ops, caffeinate: handle} = state) do
    if handle, do: safe(fn -> ops.stop_caffeinate.(handle) end, :ok, "stop caffeinate")
    safe(fn -> ops.launchd_unload.() end, :ok, "launchd unload")
    %{state | caffeinate: nil}
  end

  defp safe(fun, default, label) do
    fun.()
  rescue
    error ->
      Logger.warning("Uptime #{label} failed: #{inspect(error)}")
      default
  end

  # ---------------------------------------------------------------------------
  # Real macOS implementations (the default `:ops`)
  # ---------------------------------------------------------------------------

  defp default_ops do
    %{
      start_caffeinate: &start_caffeinate/0,
      stop_caffeinate: &stop_caffeinate/1,
      launchd_load: fn -> launchctl("load") end,
      launchd_unload: fn -> launchctl("unload") end
    }
  end

  defp start_caffeinate do
    with true <- macos?(),
         exe when is_binary(exe) <- System.find_executable("caffeinate") do
      port =
        Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:args, @caffeinate_args}])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      %{port: port, os_pid: os_pid}
    else
      _ -> nil
    end
  end

  defp stop_caffeinate(%{port: port, os_pid: os_pid}) do
    # caffeinate releases its sleep assertion the moment it dies, so a plain kill
    # is enough; close the port too so the BEAM stops tracking it.
    if os_pid, do: System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    safe_close(port)
    :ok
  end

  defp stop_caffeinate(_handle), do: :ok

  defp safe_close(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp launchctl(action) do
    plist = launchd_plist_path()

    if macos?() and is_binary(plist) and File.exists?(plist) do
      System.cmd("launchctl", [action, "-w", plist], stderr_to_stdout: true)
    end

    :ok
  end

  @doc "Path to the installed KeepAlive LaunchAgent plist (nil if no home dir)."
  def launchd_plist_path do
    case System.user_home() do
      home when is_binary(home) ->
        Path.join([home, "Library", "LaunchAgents", "#{@launchd_label}.plist"])

      _ ->
        nil
    end
  end

  defp macos?, do: :os.type() == {:unix, :darwin}
end
