defmodule BusterClaw.Browser.Bridge do
  @moduledoc """
  Request/response bridge for agent co-presence in the live browser.

  Mirrors `BusterClaw.Browser.Capture`, but instead of a single screenshot action
  it carries a small set of co-presence commands (`:current`, `:read`,
  `:navigate`, `:open_tab`) the agent can issue to read and drive the tab the
  user is viewing.

  The agent drives the Phoenix command surface, but the webviews live in the
  separate Tauri process. `request/2` issues a command: it broadcasts it (tagged
  with a unique ref) to connected top-level LiveViews, then **blocks** until the
  desktop side POSTs the result back to `/browser/command`, which calls
  `fulfill/2`. If no desktop UI answers in time, the caller gets `:browser_timeout`
  — there's simply no live browser to act on.
  """

  use GenServer

  @topic "browser_bridge"
  @default_timeout_ms 8_000
  @actions ~w(current read navigate open_tab)a

  # The internal expiry; overridable in tests via :browser_bridge_timeout_ms.
  defp timeout_ms,
    do: Application.get_env(:buster_claw, :browser_bridge_timeout_ms, @default_timeout_ms)

  # The client call waits a touch longer than the internal expiry so the GenServer
  # always replies (with a result or a clean timeout) before the call itself exits.
  defp call_timeout_ms, do: timeout_ms() + 2_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "PubSub topic command requests are broadcast on."
  def topic, do: @topic

  @doc "Subscribe the current process to command requests (used by the on_mount hook)."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Issue a co-presence command and block until the desktop side fulfils it.

  Returns `{:ok, result}` (for `:current`, `%{url:, title:}`; for the trigger
  actions, an empty map confirming success) or `{:error, reason}`
  (`:browser_unavailable`, `:browser_timeout`, or a desktop-reported reason).
  """
  def request(action, payload \\ %{}) when action in @actions and is_map(payload) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :browser_unavailable}

      _pid ->
        try do
          GenServer.call(__MODULE__, {:request, action, payload}, call_timeout_ms())
        catch
          :exit, _ -> {:error, :browser_timeout}
        end
    end
  end

  @doc "Deliver a command result for `ref` (called by the browser command controller)."
  def fulfill(ref, result) when is_binary(ref) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:fulfill, ref, result})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:request, action, payload}, from, pending) do
    ref = generate_ref()
    Process.send_after(self(), {:expire, ref}, timeout_ms())
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:browser_command, ref, action, payload})
    {:noreply, Map.put(pending, ref, from)}
  end

  @impl true
  def handle_cast({:fulfill, ref, result}, pending) do
    {:noreply, reply_and_drop(pending, ref, result)}
  end

  @impl true
  def handle_info({:expire, ref}, pending) do
    {:noreply, reply_and_drop(pending, ref, {:error, :browser_timeout})}
  end

  defp reply_and_drop(pending, ref, result) do
    case Map.pop(pending, ref) do
      {nil, pending} ->
        pending

      {from, pending} ->
        GenServer.reply(from, result)
        pending
    end
  end

  defp generate_ref do
    "cmd-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
