defmodule BusterClaw.Browser.Sidecar do
  @moduledoc """
  Supervises the optional Node Playwright browser sidecar.

  On macOS the sidecar runs inside a Seatbelt sandbox (`sandbox-exec` with
  `priv/playwright_sidecar/sandbox.sb`): reads of user data, writes outside
  the user temp/cache dirs, and exec of anything but node/the Playwright
  browsers are denied. Disable with `BUSTER_CLAW_BROWSER_SIDECAR_SANDBOX=0`.
  """

  use GenServer

  require Logger

  @restart_delay_ms 2_000
  @sandbox_exec "/usr/bin/sandbox-exec"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def url do
    case Process.whereis(__MODULE__) do
      nil ->
        :unavailable

      _pid ->
        GenServer.call(__MODULE__, :url)
    end
  end

  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{enabled: false, health: "not-started", url: nil, error: nil}

      _pid ->
        GenServer.call(__MODULE__, :status)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      opts: opts,
      port: nil,
      port_ref: nil,
      url: nil,
      health: "starting",
      error: nil,
      sandbox: false
    }

    {:ok, start_port(state)}
  end

  @impl true
  def handle_call(:url, _from, %{url: url} = state) when is_binary(url) do
    {:reply, {:ok, url}, state}
  end

  def handle_call(:url, _from, state), do: {:reply, :unavailable, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: true,
       health: state.health,
       url: state.url,
       error: state.error,
       sandbox: state.sandbox
     }, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, handle_sidecar_line(line, state)}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    {:noreply, handle_sidecar_line(line, state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Process.demonitor(state.port_ref, [:flush])
    Logger.warning("Browser sidecar exited with status #{status}")
    Process.send_after(self(), :restart_sidecar, @restart_delay_ms)

    {:noreply,
     %{state | port: nil, port_ref: nil, url: nil, health: "restarting", error: "exit #{status}"}}
  end

  def handle_info({:DOWN, ref, :port, _port, reason}, %{port_ref: ref} = state) do
    Logger.warning("Browser sidecar port went down: #{inspect(reason)}")
    Process.send_after(self(), :restart_sidecar, @restart_delay_ms)

    {:noreply,
     %{state | port: nil, port_ref: nil, url: nil, health: "restarting", error: inspect(reason)}}
  end

  def handle_info(:restart_sidecar, %{port: nil} = state), do: {:noreply, start_port(state)}
  def handle_info(:restart_sidecar, state), do: {:noreply, state}

  defp start_port(state) do
    executable = Keyword.get(state.opts, :executable) || executable()

    with {:ok, command} <- find_command(executable),
         {:ok, script} <- script_path() do
      {spawn_command, args, sandboxed?} = launch_spec(command, script)

      port =
        Port.open({:spawn_executable, spawn_command}, [
          :binary,
          :exit_status,
          {:line, 4096},
          args: args
        ])

      %{
        state
        | port: port,
          port_ref: Port.monitor(port),
          health: "starting",
          error: nil,
          sandbox: sandboxed?
      }
    else
      {:error, reason} ->
        Logger.warning("Browser sidecar unavailable: #{inspect(reason)}")
        Process.send_after(self(), :restart_sidecar, @restart_delay_ms)
        %{state | health: "unavailable", error: inspect(reason)}
    end
  end

  defp handle_sidecar_line(line, state) do
    line = to_string(line)

    case Jason.decode(line) do
      {:ok, %{"event" => "listening", "port" => port}} ->
        %{state | url: "http://127.0.0.1:#{port}", health: "available", error: nil}

      {:ok, %{"event" => "error", "message" => message}} ->
        %{state | health: "unavailable", error: message}

      {:ok, %{"event" => event}} ->
        Logger.debug("Browser sidecar event: #{event}")
        state

      _ ->
        Logger.debug("Browser sidecar: #{String.trim(line)}")
        state
    end
  end

  defp executable do
    Application.get_env(:buster_claw, :browser_sidecar_command, "node")
  end

  @doc false
  # Returns {command, args, sandboxed?} for Port.open. Public for tests.
  def launch_spec(command, script) do
    if sandbox_enabled?() do
      case sandbox_args(command, script) do
        {:ok, args} ->
          {@sandbox_exec, args, true}

        {:error, reason} ->
          Logger.warning(
            "Browser sidecar sandbox unavailable (#{inspect(reason)}); running unsandboxed"
          )

          {command, [script], false}
      end
    else
      {command, [script], false}
    end
  end

  defp sandbox_enabled? do
    :os.type() == {:unix, :darwin} and
      Application.get_env(:buster_claw, :browser_sidecar_sandbox, true) and
      File.exists?(@sandbox_exec)
  end

  defp sandbox_args(command, script) do
    with {:ok, node_bin} <- resolve_symlinks(command),
         {:ok, sidecar_dir} <- resolve_symlinks(Path.dirname(script)),
         {:ok, profile} <- profile_path(script),
         {:ok, user_temp} <- darwin_user_dir("DARWIN_USER_TEMP_DIR"),
         {:ok, user_cache} <- darwin_user_dir("DARWIN_USER_CACHE_DIR") do
      params = [
        {"NODE_BIN", node_bin},
        {"NODE_ROOT", node_root(node_bin)},
        {"SIDECAR_DIR", sidecar_dir},
        {"PW_BROWSERS", playwright_browsers_dir()},
        {"USER_TEMP", user_temp},
        {"USER_CACHE", user_cache}
      ]

      args =
        ["-f", profile] ++
          Enum.flat_map(params, fn {name, value} -> ["-D", "#{name}=#{value}"] end) ++
          [node_bin, script]

      {:ok, args}
    end
  end

  defp profile_path(script) do
    path = Path.join(Path.dirname(script), "sandbox.sb")

    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:missing_sandbox_profile, path}}
    end
  end

  # Seatbelt evaluates canonical (symlink-resolved) paths, so the -D params
  # must be canonical too. Symlinks can sit mid-path (_build/.../priv points
  # at the source priv), so every component is resolved, not just the leaf.
  defp resolve_symlinks(path) do
    path |> Path.expand() |> Path.split() |> resolve_components(nil, 0)
  end

  defp resolve_components([], acc, _hops), do: {:ok, acc}

  defp resolve_components([component | rest], acc, hops) do
    candidate = if acc, do: Path.join(acc, component), else: component

    case File.read_link(candidate) do
      {:ok, _target} when hops >= 32 ->
        {:error, :symlink_loop}

      {:ok, target} ->
        resolved = Path.expand(target, Path.dirname(candidate))
        resolve_components(Path.split(resolved) ++ rest, nil, hops + 1)

      {:error, _} ->
        resolve_components(rest, candidate, hops)
    end
  end

  # The prefix that holds node plus the dylibs it links (Homebrew links ICU
  # and friends from the prefix root, not node's own tree).
  defp node_root(node_bin) do
    cond do
      String.starts_with?(node_bin, "/usr/local/") -> "/usr/local"
      String.starts_with?(node_bin, "/opt/homebrew/") -> "/opt/homebrew"
      true -> node_bin |> Path.dirname() |> Path.dirname()
    end
  end

  defp playwright_browsers_dir do
    System.get_env("PLAYWRIGHT_BROWSERS_PATH") ||
      Path.expand("~/Library/Caches/ms-playwright")
  end

  defp darwin_user_dir(name) do
    case System.cmd("getconf", [name]) do
      {out, 0} ->
        dir = out |> String.trim() |> String.trim_trailing("/")
        # canonicalize: /var is a symlink to /private/var
        dir = if String.starts_with?(dir, "/var/"), do: "/private" <> dir, else: dir
        {:ok, dir}

      {_out, status} ->
        {:error, {:getconf_failed, name, status}}
    end
  rescue
    error -> {:error, {:getconf_unavailable, Exception.message(error)}}
  end

  defp find_command(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) ->
        {:ok, command}

      found = System.find_executable(command) ->
        {:ok, found}

      true ->
        {:error, {:missing_executable, command}}
    end
  end

  defp script_path do
    case :code.priv_dir(:buster_claw) do
      {:error, reason} ->
        {:error, {:missing_priv_dir, reason}}

      priv_dir ->
        path = Path.join([priv_dir, "playwright_sidecar", "server.js"])

        if File.exists?(path) do
          {:ok, path}
        else
          {:error, {:missing_sidecar_script, path}}
        end
    end
  end
end
