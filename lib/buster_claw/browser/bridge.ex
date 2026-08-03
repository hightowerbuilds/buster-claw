defmodule BusterClaw.Browser.Bridge do
  @moduledoc """
  Request/response bridge for agent co-presence in the live browser.

  Mirrors `BusterClaw.Browser.Capture`, but instead of a single screenshot action
  it carries a small set of co-presence commands (`:current`, `:read`,
  `:find_elements`, `:click`, `:fill`, `:navigate`, `:open_tab`, `:render`,
  `:wait`, `:extract`) the agent can issue to read and drive the tab the user
  is viewing — or, for `:render`, to load a URL in a hidden ephemeral webview
  when the plain-HTTP fetch pipeline can't produce readable content.

  The agent drives the Phoenix command surface, but the webviews live in the
  separate Tauri process. `request/3` issues a command: it broadcasts it (tagged
  with a unique ref) to connected top-level LiveViews, then **blocks** until the
  desktop side POSTs the result back to `/browser/command`, which calls
  `fulfill/2`. If no desktop UI answers in time, the caller gets `:browser_timeout`
  — there's simply no live browser to act on. `available?/0` reports whether any
  shell LiveView is currently subscribed, so slow-to-fail paths (the fetch
  fallback) can skip the wait entirely when no desktop is attached.
  """

  use GenServer

  @topic "browser_bridge"
  @default_timeout_ms 8_000
  @actions ~w(current read find_elements click fill navigate open_tab render wait extract)a

  # The payload keys each action may carry, and the other half of the JS
  # contract. `@actions` kept the two sides agreeing on the verb; nothing kept
  # them agreeing on the arguments, so renaming `"wait_ms"` on either side
  # produced no error anywhere — the hook would read `undefined` and the command
  # would quietly do the wrong thing.
  #
  # Declared here rather than inferred from callers, because payloads are built
  # in several modules (`Commands.Web` and `Browser` both do) and a regex over
  # call sites cannot tell a request key from a response key. `payload_keys/1`
  # is what `BridgeLockstepTest` compares against the hook's `payload.<key>`
  # reads, so this attribute is the contract, not a description of one.
  @payload_keys %{
    current: [],
    read: [],
    find_elements: ["query"],
    click: ["index", "selector", "text"],
    fill: ["index", "selector", "text", "value"],
    navigate: ["url"],
    open_tab: ["url", "session"],
    render: ["url", "wait_ms"],
    wait: ["condition", "value", "timeout_ms"],
    extract: ["selector", "attr"]
  }

  @doc "Payload keys `action` may carry — the Elixir half of the JS contract."
  def payload_keys(action) when action in @actions, do: Map.fetch!(@payload_keys, action)

  @doc "Every action with its declared payload keys."
  def payload_contract, do: @payload_keys

  # The internal expiry; overridable in tests via :browser_bridge_timeout_ms.
  defp timeout_ms,
    do: Application.get_env(:buster_claw, :browser_bridge_timeout_ms, @default_timeout_ms)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "PubSub topic command requests are broadcast on."
  def topic, do: @topic

  @doc "Subscribe the current process to command requests (used by the on_mount hook)."
  def subscribe do
    GenServer.cast(__MODULE__, {:track, self()})
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)
  end

  @doc """
  Whether a desktop shell is listening right now (any live subscriber). Lets
  optional co-presence work — like the live-render fetch fallback — bail out
  instantly instead of blocking a full request timeout when the app isn't open.
  """
  def available? do
    case Process.whereis(__MODULE__) do
      nil ->
        false

      _pid ->
        try do
          GenServer.call(__MODULE__, :available?, 1_000)
        catch
          :exit, _ -> false
        end
    end
  end

  @doc """
  Issue a co-presence command and block until the desktop side fulfils it.

  Returns `{:ok, result}` (for `:current`, `%{url:, title:}`; for `:read`,
  `:render`, `:wait`, and `:extract`, `%{data: json}`; for the trigger actions,
  an empty map confirming success) or `{:error, reason}` (`:browser_unavailable`,
  `:browser_timeout`, or a desktop-reported reason).

  Options: `:timeout_ms` overrides the per-request expiry — `:render` and
  `:wait` block on real page activity, so their callers pass a budget above
  the 8s default.
  """
  def request(action, payload \\ %{}, opts \\ [])
      when action in @actions and is_map(payload) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout_ms, timeout_ms())

    # A key the hook does not read is a caller bug that used to be invisible:
    # the command ran, the argument vanished, and the result looked like a page
    # that simply did not match. Refuse it here instead.
    case Map.keys(payload) -- payload_keys(action) do
      [] -> :ok
      unknown -> raise ArgumentError, bad_payload_message(action, unknown)
    end

    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :browser_unavailable}

      _pid ->
        try do
          GenServer.call(__MODULE__, {:request, action, payload, timeout}, timeout + 2_000)
        catch
          :exit, _ -> {:error, :browser_timeout}
        end
    end
  end

  defp bad_payload_message(action, unknown) do
    """
    Bridge.request(#{inspect(action)}, …) was given #{inspect(unknown)}, which \
    the browser hook never reads.

    Declared keys for #{inspect(action)}: #{inspect(payload_keys(action))}.

    Either the key is a typo, or the contract moved and both @payload_keys here \
    and assets/js/hooks/browser.js need it.\
    """
  end

  @doc "Deliver a command result for `ref` (called by the browser command controller)."
  def fulfill(ref, result) when is_binary(ref) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:fulfill, ref, result})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}, subscribers: MapSet.new()}}

  @impl true
  def handle_call({:request, action, payload, timeout}, from, state) do
    ref = generate_ref()
    Process.send_after(self(), {:expire, ref}, timeout)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:browser_command, ref, action, payload})
    {:noreply, put_in(state.pending[ref], from)}
  end

  def handle_call(:available?, _from, state) do
    {:reply, MapSet.size(state.subscribers) > 0, state}
  end

  @impl true
  def handle_cast({:fulfill, ref, result}, state) do
    {:noreply, reply_and_drop(state, ref, result)}
  end

  def handle_cast({:track, pid}, state) do
    if MapSet.member?(state.subscribers, pid) do
      {:noreply, state}
    else
      Process.monitor(pid)
      {:noreply, update_in(state.subscribers, &MapSet.put(&1, pid))}
    end
  end

  @impl true
  def handle_info({:expire, ref}, state) do
    {:noreply, reply_and_drop(state, ref, {:error, :browser_timeout})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, update_in(state.subscribers, &MapSet.delete(&1, pid))}
  end

  defp reply_and_drop(state, ref, result) do
    case Map.pop(state.pending, ref) do
      {nil, pending} ->
        %{state | pending: pending}

      {from, pending} ->
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end

  defp generate_ref do
    "cmd-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
