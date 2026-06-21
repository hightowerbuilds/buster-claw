defmodule BusterClaw.Browser.Capture do
  @moduledoc """
  Request/response bridge for capturing a screenshot of the live browser.

  The agent drives the Phoenix command surface, but the webviews live in the
  separate Tauri process. `request/1` issues a capture: it broadcasts a request
  (tagged with a unique ref) to connected top-level LiveViews, then **blocks**
  until the desktop side POSTs the PNG back to `/browser/screenshot`, which calls
  `fulfill/2`. If no desktop UI answers in time, the caller gets `:capture_timeout`
  — there's simply nothing to screenshot.

  Mirrors the broadcast pattern of `BusterClaw.TerminalWorkspace`, but with a
  ref→`from` correlation map so a single response can reply to the right caller.
  """

  use GenServer

  @topic "browser_capture"
  @default_timeout_ms 10_000

  # The internal expiry; overridable in tests via :browser_capture_timeout_ms.
  defp timeout_ms,
    do: Application.get_env(:buster_claw, :browser_capture_timeout_ms, @default_timeout_ms)

  # The client call waits a touch longer than the internal expiry so the GenServer
  # always replies (with a result or a clean timeout) before the call itself exits.
  defp call_timeout_ms, do: timeout_ms() + 2_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "PubSub topic capture requests are broadcast on."
  def topic, do: @topic

  @doc "Subscribe the current process to capture requests (used by the on_mount hook)."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Request a screenshot of the active browser tab. Blocks until the desktop side
  fulfils it. Returns `{:ok, %{path:, url:, bytes:}}` or `{:error, reason}`
  (`:capture_unavailable`, `:capture_timeout`, or a desktop-reported reason).
  """
  def request(opts \\ []) when is_list(opts) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :capture_unavailable}

      _pid ->
        try do
          GenServer.call(__MODULE__, {:request, opts}, call_timeout_ms())
        catch
          :exit, _ -> {:error, :capture_timeout}
        end
    end
  end

  @doc "Deliver a capture result for `ref` (called by the screenshot controller)."
  def fulfill(ref, result) when is_binary(ref) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:fulfill, ref, result})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:request, _opts}, from, pending) do
    ref = generate_ref()
    Process.send_after(self(), {:expire, ref}, timeout_ms())
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:capture, ref})
    {:noreply, Map.put(pending, ref, from)}
  end

  @impl true
  def handle_cast({:fulfill, ref, result}, pending) do
    {:noreply, reply_and_drop(pending, ref, result)}
  end

  @impl true
  def handle_info({:expire, ref}, pending) do
    {:noreply, reply_and_drop(pending, ref, {:error, :capture_timeout})}
  end

  defp reply_and_drop(pending, ref, result) do
    case Map.pop(pending, ref) do
      {nil, pending} -> pending
      {from, pending} -> GenServer.reply(from, result); pending
    end
  end

  defp generate_ref do
    "cap-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
