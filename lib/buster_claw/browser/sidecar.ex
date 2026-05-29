defmodule BusterClaw.Browser.Sidecar do
  @moduledoc "Supervises the optional Node Playwright browser sidecar."

  use GenServer

  require Logger

  @restart_delay_ms 2_000

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
      error: nil
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
       error: state.error
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
      port =
        Port.open({:spawn_executable, command}, [
          :binary,
          :exit_status,
          {:line, 4096},
          args: [script]
        ])

      %{state | port: port, port_ref: Port.monitor(port), health: "starting", error: nil}
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
