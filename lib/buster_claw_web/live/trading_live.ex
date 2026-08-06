defmodule BusterClawWeb.TradingLive do
  @moduledoc """
  The top-level Trading workspace: an accounts dashboard plus a strip of typed
  Robinhood and Chart Build conversations.

  ## The chat

  Each typed conversation keeps independent transcript, run, window, and unread
  state. Robinhood chat uses the broker read allowlist; Chart Build is a confined
  authoring *and* data-research mode — cached snapshot plus web search, no broker
  tool at all — whose sanitized SVG output is previewed above its embedded chat
  and whose app-fetched figures render in the lookup panel beside it. Every send
  lands a Sentinel `:outbound_send` line — the audit posture for money-adjacent
  turns.

  A `research` kind sat between the two until 08-03; Chart Build absorbed its job
  and its fetchers (`daily-growth/roadmaps/CHART_BUILD_WEB_DATA_ROADMAP.md`).

  ## The dashboard

  Stage-1 balances (all accounts), stage-2 holdings on demand, cumulative
  gain/loss, positions, symbol charts, transfer state, exclusions, and backfill
  controls are backed by the existing Trading and Portfolio contexts.
  """
  use BusterClawWeb, :live_view

  # The dashboard's pure view model — state classifiers and formatters. Imported
  # rather than aliased so the templates keep calling them by bare name.
  import BusterClawWeb.TradingView
  import BusterClawWeb.TradingAccountCard, only: [trading_account_card: 1]
  import BusterClawWeb.ChartBuilderPanel, only: [chart_preview: 1]
  import BusterClawWeb.WatchlistSidebar, only: [watchlist_sidebar: 1]
  import BusterClawWeb.TradingLookupPanel, only: [lookup_card: 1]
  import BusterClawWeb.TradingTabStrip, only: [trading_tabs: 1]
  import BusterClawWeb.TradingOrderCard, only: [order_confirm: 1]

  require Logger

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.ChartBuilder.DataReq
  alias BusterClaw.ChartBuilder.Fetch
  alias BusterClaw.DataState
  alias BusterClaw.MarketData
  alias BusterClaw.Portfolio
  alias BusterClaw.SvgViewer
  alias BusterClaw.Trading
  alias BusterClaw.Watchlist

  # The combined-total chip. A sentinel rather than nil so the selection is
  # always an explicit choice, and so it round-trips through phx-value-id.
  @all_accounts "__all__"
  @portfolio_ranges ~w(1W 1M 3M 1Y ALL)
  @symbol_ranges ~w(1M 3M 1Y 5Y)
  @symbol_modes ~w(line candles)

  # Cap the retained in-memory transcript on a long-lived tab; the persisted
  # transcript is the source of truth and is re-read on mount.
  @max_chat_messages 200
  @max_chat_svgs 200

  # How many app-side data fetches one Chart Build conversation may trigger
  # before the operator speaks again. The brake exists because a `datareq` is a
  # turn that can provoke another `datareq`: without a bound, a model that keeps
  # rephrasing a request it cannot satisfy burns tokens in a loop nobody is
  # watching. Reset on every operator message — a human in the loop is the
  # thing the budget stands in for.
  @datareq_budget 6

  @impl true
  def mount(_params, _session, socket) do
    # Every open tab is subscribed, not just the active one: a run keeps going
    # when you switch away, and its tab has to be able to show an unread dot.
    tabs = Trading.tabs()
    active = hd(tabs)
    if connected?(socket), do: Enum.each(tabs, &Chat.subscribe(&1.id))

    socket =
      socket
      |> assign(:page_title, "Trading")
      # Last delivery outcome, announced politely by the composer. One per
      # LiveView rather than per window: the operator submits one message at a
      # time, and the announcement is about that action.
      |> assign(:chat_announcement, nil)
      # The left rail, open by default like the Workspace tab's: it carries the
      # symbol lookup on Chart Build, and a search box nobody can see is not a
      # search box. The account UI still owns the tab — only ticker things live
      # in here.
      |> assign(:watchlist_open, true)
      |> assign_watchlists()
      # Joined into a split pane (`SplitLive`), this tab is half a window rather
      # than a whole one. The only thing that changes is where the floating chat
      # windows are allowed to go — see `trading-root` in `render/1`.
      |> assign(:embedded?, BusterClawWeb.ChromeHook.embedded?())
      |> assign(:agent_cli_missing, trading_cli_missing?())
      |> assign(:tabs, Enum.map(tabs, &to_tab/1))
      |> assign(:active_tab, active.id)
      |> assign(:active_kind, active.kind)
      |> assign(:new_tab_open, false)
      # Lookup panel state per conversation, so switching tabs doesn't lose
      # the symbol a tab was looking at.
      |> assign(:lookup, %{})
      |> assign(:lookup_query, "")
      |> assign(:lookup_matches, [])
      # Which match the keyboard is on. nil = none; the mouse never sets it, so
      # a hover and an arrow key cannot disagree about what Enter would open.
      |> assign(:lookup_cursor, nil)
      # One state map per conversation. Several windows render at once, so there
      # is no single "the chat" to hold running/queue/transcript for any more.
      |> assign(:chats, Map.new(tabs, &{&1.id, initial_chat_state(&1.id, &1.kind)}))
      # Render order, and focus order: the last entry is the focused window.
      |> assign(:open_chats, [active.id])
      |> assign(:minimized, MapSet.new())
      # Accounts panel: nil | {:loading, prev} | {:ok, snap} |
      # {:error, reason, prev} — prev = last good snapshot (or nil), kept visible
      # under the spinner/error line instead of blanking real data.
      |> assign(:trading_account, nil)
      # Which account's detail is expanded. An id, not an index: a refresh can
      # reorder or drop accounts, and Trading.select_account/2 falls back when
      # the id is gone, so a stale selection can never point at someone else's
      # money. Starts on the combined total.
      |> assign(:trading_account_sel, @all_accounts)
      # The combined-total sentinel, assigned so the accounts panel can compare
      # against it inside a template (where `@all_accounts` means the assign).
      |> assign(:all_accounts, @all_accounts)
      # Stage 2 (one account's holdings/orders): nil | {:loading, id} |
      # {:error, id, reason}.
      |> assign(:trading_detail, nil)
      |> assign(:trading_anomaly, nil)
      |> assign(:trading_range, "1M")
      |> assign(:trading_range_pinned, false)
      |> assign(:trading_series, [])
      |> assign(:trading_coverage, nil)
      |> assign(:trading_backfilling, false)
      |> assign(:trading_table, false)
      |> assign(:trading_costs_loading, false)
      # The chart pane: the portfolio gain/loss line, or one symbol's price
      # chart (Phase 4). Line mode is the default because it renders from
      # cached closes with no run; candles are one click and (at most) one
      # bounded fetch away.
      |> assign(:trading_chart_view, :portfolio)
      |> assign(:symbol_range, "3M")
      |> assign(:symbol_mode, :line)
      |> assign(:symbol_bars, [])
      |> assign(:symbol_bars_state, DataState.unavailable(:not_loaded, source: :price_history))
      # nil | {symbol, interval, requested_from}. Keeping the request identity
      # prevents an obsolete completion from clearing a newer loading state.
      |> assign(:symbol_bars_request, nil)

    # The static (disconnected) render must not spend agent runs: show whatever
    # is cached; fetches start once the socket is live.
    socket =
      if connected?(socket),
        do: load_trading_account(socket),
        else: socket |> assign_cached_snapshot() |> load_chart()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Chat events
  # ---------------------------------------------------------------------------

  @impl true
  # The window's composer names its conversation in a hidden field: with several
  # open at once, "the chat" is no longer a thing the server can infer.
  def handle_event("chat_send", %{"message" => text} = params, socket) do
    # Sending barges in on any reply still being spoken.
    socket = push_event(socket, "bc:stop_speak", %{})
    conv = params["conv"] || socket.assigns.active_tab

    case {known_tab?(socket, conv), String.trim(text)} do
      {true, trimmed} when trimmed != "" ->
        # An operator turn refills the data-request budget: the brake exists to
        # bound an unwatched loop, and someone typing is the end of unwatched.
        {:noreply,
         socket
         |> reset_datareq_budget(conv)
         |> dispatch_chat(conv, trimmed, delivery_param(params))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_queued", %{"id" => id} = params, socket) do
    conv = params["conv"] || socket.assigns.active_tab

    with true <- known_tab?(socket, conv), {qid, ""} <- Integer.parse(id) do
      Chat.remove_queued(conv, qid)
    end

    {:noreply, socket}
  end

  def handle_event("cut_run", params, socket) do
    conv = params["conv"] || socket.assigns.active_tab
    if known_tab?(socket, conv), do: Chat.interrupt(conv)
    {:noreply, push_event(socket, "bc:stop_speak", %{})}
  end

  # ---------------------------------------------------------------------------
  # Tabs — each one a typed conversation
  # ---------------------------------------------------------------------------

  def handle_event("trading_select_tab", %{"id" => id}, socket) do
    if known_tab?(socket, id), do: {:noreply, activate_tab(socket, id)}, else: {:noreply, socket}
  end

  def handle_event("trading_new_tab_menu", _params, socket) do
    {:noreply, assign(socket, :new_tab_open, not socket.assigns.new_tab_open)}
  end

  def handle_event("trading_new_tab", %{"kind" => kind}, socket)
      when kind in ["chat", "robinhood", "chartbuild"] do
    # A new tab starts docked — it opens as a sub-tab rather than a window the
    # operator has to place. The exception is a kind that HAS a data panel:
    # docking a Robinhood tab hides the very dashboard you just asked for, so it
    # starts with the panel showing and the chat floating over it. Either can be
    # dragged or buttoned into the other state after. (Chart Build owns both
    # halves of its tab, so its dock flag stays false for a different reason.)
    docked = kind == "chat"

    {:ok, conv} =
      Conversations.create(%{title: Trading.kind_label(kind), kind: kind, docked: docked})

    if connected?(socket), do: Chat.subscribe(conv.id)

    # A tab you just made is one you want to talk to, so a floating one opens
    # with it — and appended, so it is the focused one. Selecting an EXISTING
    # tab deliberately does not do this: a window the operator closed stays
    # closed. A docked tab needs no window; it is already the tab.
    open_chats =
      if docked or kind == "chartbuild",
        do: socket.assigns.open_chats,
        else: socket.assigns.open_chats ++ [conv.id]

    {:noreply,
     socket
     |> assign(:tabs, socket.assigns.tabs ++ [to_tab(conv)])
     |> assign(:new_tab_open, false)
     |> assign(:open_chats, open_chats)
     |> activate_tab(conv.id)}
  end

  def handle_event("trading_new_tab", _params, socket),
    do: {:noreply, assign(socket, :new_tab_open, false)}

  def handle_event("trading_close_tab", %{"id" => id}, socket) do
    if known_tab?(socket, id), do: {:noreply, close_tab(socket, id)}, else: {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Chat windows — floating, and independent of which panel is showing
  # ---------------------------------------------------------------------------

  def handle_event("watchlist_toggle", _params, socket) do
    {:noreply, update(socket, :watchlist_open, &(not &1))}
  end

  def handle_event("watchlist_create", %{"name" => name}, socket) do
    {:noreply, flash_watchlist(socket, Watchlist.create(name))}
  end

  def handle_event("watchlist_delete", %{"name" => name}, socket) do
    {:noreply, flash_watchlist(socket, Watchlist.delete(name))}
  end

  def handle_event("watchlist_add", %{"name" => name, "symbol" => symbol}, socket) do
    {:noreply, flash_watchlist(socket, Watchlist.add(name, symbol))}
  end

  def handle_event("watchlist_remove", %{"name" => name, "symbol" => symbol}, socket) do
    {:noreply, flash_watchlist(socket, Watchlist.remove(name, symbol))}
  end

  def handle_event("trading_toggle_chat", %{"id" => id}, socket) do
    cond do
      not known_tab?(socket, id) ->
        {:noreply, socket}

      id in socket.assigns.open_chats ->
        {:noreply,
         socket
         |> assign(:open_chats, List.delete(socket.assigns.open_chats, id))
         |> update(:minimized, &MapSet.delete(&1, id))}

      true ->
        # Appended, so a newly opened window is the focused one.
        {:noreply,
         socket
         |> assign(:open_chats, socket.assigns.open_chats ++ [id])
         |> update_tab(id, &%{&1 | unread: false})}
    end
  end

  def handle_event("trading_minimize_chat", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :minimized, fn mins ->
       if MapSet.member?(mins, id), do: MapSet.delete(mins, id), else: MapSet.put(mins, id)
     end)}
  end

  def handle_event("trading_focus_chat", %{"id" => id}, socket) do
    # Focus is render order: move this window to the end so it draws last, is
    # the opaque one, and takes the keyboard.
    if id in socket.assigns.open_chats do
      {:noreply,
       socket
       |> assign(:open_chats, List.delete(socket.assigns.open_chats, id) ++ [id])
       |> update_tab(id, &%{&1 | unread: false})}
    else
      {:noreply, socket}
    end
  end

  # Dropping a floating window on the tab bar is the dock gesture; the button in
  # a docked chat's header is the way back out.
  def handle_event("trading_dock_chat", %{"id" => id}, socket) do
    if known_tab?(socket, id) do
      {:ok, _conv} = Conversations.set_docked(id, true)

      {:noreply,
       socket
       |> update_tab(id, &%{&1 | docked: true, unread: false})
       # A docked chat is not also a window: it lives in the tab now.
       |> assign(:open_chats, List.delete(socket.assigns.open_chats, id))
       |> update(:minimized, &MapSet.delete(&1, id))
       |> activate_tab(id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("trading_float_chat", %{"id" => id}, socket) do
    if known_tab?(socket, id) do
      {:ok, _conv} = Conversations.set_docked(id, false)

      {:noreply,
       socket
       |> update_tab(id, &%{&1 | docked: false})
       |> assign(:open_chats, socket.assigns.open_chats ++ [id])}
    else
      {:noreply, socket}
    end
  end

  # Retyping a conversation changes what it can reach, so the running process is
  # stopped: its session id dies with it and the next message starts a FRESH
  # claude session. Without that, a Robinhood chat retyped to Chart Build would
  # `--resume` into a context full of account balances that the Chart Build
  # toolset is specifically supposed to have no way of seeing — and Chart Build
  # can now search the web, which makes the leak worse than it used to be.
  def handle_event("trading_set_kind", %{"id" => id, "kind" => kind}, socket)
      when kind in ["chat", "robinhood", "chartbuild"] do
    if known_tab?(socket, id) and tab_kind(socket, id) != kind do
      previous_kind = tab_kind(socket, id)
      {:ok, _conv} = Conversations.set_kind(id, kind)
      Chat.stop(id)

      socket =
        socket
        |> update_tab(id, &%{&1 | kind: kind, running: false})
        |> put_chat(id, fn chat ->
          if kind == "chartbuild" do
            chart_state = initial_chat_state(id, kind)
            %{chart_state | running: false, thinking: nil, queue: []}
          else
            %{chat | running: false, thinking: nil, queue: [], pending_order: nil}
          end
        end)
        |> transition_chartbuild_layout(id, previous_kind, kind)

      {:noreply,
       socket
       |> push_msg_to(
         id,
         :meta,
         "Switched to #{Trading.kind_label(kind)}. This starts a new session — the " <>
           "assistant will not see anything above this line."
       )
       |> then(&assign(&1, :active_kind, active_tab_kind(&1)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("trading_set_kind", _params, socket), do: {:noreply, socket}

  # Chart Build reuses Home's hardened SVG viewer. The preview shows the newest
  # chart; these events open and page through the whole active conversation.
  def handle_event("zoom_svg", %{"id" => id}, socket) do
    with {chart_id, ""} <- Integer.parse(id),
         true <- Enum.any?(active_charts(socket.assigns), &(&1.id == chart_id)) do
      {:noreply, put_chat(socket, socket.assigns.active_tab, &%{&1 | zoomed_id: chart_id})}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("close_zoom", _params, socket),
    do: {:noreply, put_chat(socket, socket.assigns.active_tab, &%{&1 | zoomed_id: nil})}

  def handle_event("zoom_nav", %{"dir" => dir}, socket),
    do: {:noreply, chart_zoom_step(socket, dir)}

  def handle_event("zoom_key", %{"key" => "Escape"}, socket),
    do: {:noreply, put_chat(socket, socket.assigns.active_tab, &%{&1 | zoomed_id: nil})}

  def handle_event("zoom_key", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, chart_zoom_step(socket, "prev")}

  def handle_event("zoom_key", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, chart_zoom_step(socket, "next")}

  def handle_event("zoom_key", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Symbol lookup panel
  # ---------------------------------------------------------------------------

  def handle_event("lookup_search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:lookup_query, query)
     |> assign(:lookup_matches, Fetch.search(query))
     # New matches, so the old index means nothing.
     |> assign(:lookup_cursor, nil)}
  end

  def handle_event("lookup_open", %{"symbol" => symbol}, socket) do
    # Loaded synchronously: three small HTTP GETs against free endpoints, not an
    # agent run. There is no token cost to defer and no model to wait for.
    {:noreply,
     socket
     |> put_lookup(Fetch.load(symbol))
     |> assign(:lookup_query, "")
     |> assign(:lookup_matches, [])
     |> assign(:lookup_cursor, nil)}
  end

  # Keyboard navigation of the match list. Pure LiveView: `phx-keydown` on the
  # input and an index in the assigns, the same instinct as the rail's bumper —
  # a JS hook would be a second way to do a thing this app already does simply.
  #
  # The arrow keys are NOT preventDefault'd (no hook, no way to), so Down also
  # drops the caret to the end of the input. In a single-line search box that is
  # invisible, and it is the price of not owning a hook.
  def handle_event("lookup_key", %{"key" => key}, socket) do
    {:noreply, move_lookup_cursor(socket, key)}
  end

  def handle_event("lookup_clear", _params, socket) do
    {:noreply,
     socket
     |> put_lookup(Fetch.blank())
     |> assign(:lookup_query, "")
     |> assign(:lookup_matches, [])
     |> assign(:lookup_cursor, nil)}
  end

  # ---------------------------------------------------------------------------
  # The order confirmation — the only path from this tab to the broker
  # ---------------------------------------------------------------------------

  # The click names WHICH card was pressed and nothing else. The order that gets
  # placed is still the one the app parsed and holds in that conversation's
  # state — a forged conv id can only reach a conversation whose own pending
  # order is already {:proposed, …}, and it cannot alter a single parameter.
  def handle_event("trading_order_confirm", params, socket) do
    conv = params["conv"] || socket.assigns.active_tab

    case chat_state(socket.assigns, conv) do
      %{pending_order: {:proposed, order}} ->
        # The harness and model are on the record at the moment of confirmation,
        # not inferred later from settings that may have changed since. This is
        # the money path; "what ran this order" has to be answerable from the
        # feed alone.
        BusterClaw.Sentinel.observe(:outbound_send, "Trading order confirmed by operator", %{
          source: "trading_chat_order",
          conv_id: conv,
          order: BusterClaw.TradingOrder.summary(order),
          agent: BusterClaw.ModelPolicy.backend_for(:order_submit),
          model: BusterClaw.ModelPolicy.for_surface(:order_submit) || "cli default"
        })

        {:noreply,
         socket
         |> put_chat(conv, &%{&1 | pending_order: {:submitting, order}})
         |> start_async({:trading_order, conv}, fn -> BusterClaw.TradingOrder.submit(order) end)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("trading_order_dismiss", params, socket) do
    conv = params["conv"] || socket.assigns.active_tab

    case chat_state(socket.assigns, conv) do
      # Refuse to clear a card whose run is still out: the operator would be left
      # believing nothing happened while a place call is in flight.
      %{pending_order: {:submitting, _order}} ->
        {:noreply, socket}

      _other ->
        {:noreply, put_chat(socket, conv, &%{&1 | pending_order: nil})}
    end
  end

  # ---------------------------------------------------------------------------
  # Dashboard events
  # ---------------------------------------------------------------------------

  def handle_event("trading_refresh", _params, socket) do
    {:noreply, maybe_refresh_account(socket)}
  end

  # "Was that a transfer?" — the answer to the anomaly prompt. `kind` decides
  # whether the amount is money in, money out, or nothing at all; the amount
  # itself is always the day's raw change, which is what the user is looking at.
  def handle_event("trading_mark_flow", %{"kind" => kind, "day" => day} = params, socket) do
    with %{account_key: expected_key, day: expected_day} <- socket.assigns.trading_anomaly,
         {:ok, day} <- Date.from_iso8601(day),
         account_key when is_binary(account_key) <- params["account_key"],
         true <- day == expected_day,
         true <- account_key == expected_key,
         true <- account_key in ledger_keys(socket),
         {:ok, cents} <- flow_cents(kind, params["amount"]) do
      attrs = %{
        account_key: account_key,
        occurred_on: day,
        amount_cents: cents,
        kind: kind,
        note: params["note"],
        source: "manual"
      }

      case Portfolio.put_flow(attrs) do
        {:ok, _flow} ->
          # The gain math just changed underneath the chart.
          {:noreply, socket |> assign(:trading_anomaly, nil) |> load_chart()}

        {:error, _changeset} ->
          {:noreply,
           push_msg(socket, :error, "That transfer didn't look right — check the amount.")}
      end
    else
      _error ->
        {:noreply, push_msg(socket, :error, "Couldn't record that transfer.")}
    end
  end

  def handle_event("trading_toggle_excluded", %{"id" => key}, socket) do
    if key in ledger_keys(socket) do
      if Portfolio.excluded?(key),
        do: Portfolio.include_account(key),
        else: Portfolio.exclude_account(key)
    end

    {:noreply, load_chart(socket)}
  end

  def handle_event("trading_toggle_table", _params, socket) do
    {:noreply, update(socket, :trading_table, &(!&1))}
  end

  def handle_event("trading_select_range", %{"range" => range}, socket) do
    if range in @portfolio_ranges do
      {:noreply,
       socket
       |> assign(:trading_range, range)
       |> assign(:trading_range_pinned, true)}
    else
      {:noreply, socket}
    end
  end

  # Only ever fills accounts that are missing history — a repair, not a refresh;
  # re-fetching what we already have would spend real agent runs to learn nothing.
  def handle_event("trading_backfill", _params, socket) do
    case socket.assigns.trading_coverage do
      %{missing: [_ | _] = missing} when not socket.assigns.trading_backfilling ->
        {:noreply,
         socket
         |> assign(:trading_backfilling, true)
         |> start_async(:trading_backfill, fn ->
           Enum.map(missing, &{&1, Portfolio.backfill(&1)})
         end)}

      _other ->
        {:noreply, socket}
    end
  end

  # --- Symbol chart (Phase 4) ---

  def handle_event("trading_view_symbol", %{"symbol" => symbol}, socket) do
    symbol = symbol |> String.trim() |> String.upcase()

    if symbol in allowed_symbols(socket) do
      {:noreply,
       socket
       |> assign(:trading_chart_view, {:symbol, symbol})
       |> load_symbol_bars()
       |> maybe_fetch_symbol_bars()}
    else
      {:noreply, socket}
    end
  end

  # The done-when: "Portfolio" returns to the gain/loss line.
  def handle_event("trading_view_portfolio", _params, socket) do
    {:noreply, socket |> assign(:trading_chart_view, :portfolio) |> assign(:symbol_bars, [])}
  end

  def handle_event("trading_symbol_range", %{"range" => range}, socket)
      when range in @symbol_ranges do
    {:noreply,
     socket
     |> assign(:symbol_range, range)
     |> load_symbol_bars()
     |> maybe_fetch_symbol_bars()}
  end

  def handle_event("trading_symbol_range", _params, socket), do: {:noreply, socket}

  def handle_event("trading_symbol_mode", %{"mode" => mode}, socket)
      when mode in @symbol_modes do
    {:noreply,
     socket
     |> assign(:symbol_mode, String.to_existing_atom(mode))
     |> load_symbol_bars()
     |> maybe_fetch_symbol_bars()}
  end

  def handle_event("trading_symbol_mode", _params, socket), do: {:noreply, socket}

  # Load/refresh cost basis: one agent run per named account, exactly like the
  # backfill. "Load" spends runs only on accounts with nothing; "Refresh"
  # re-fetches every included holdings-capable account.
  def handle_event("trading_load_costs", _params, socket) do
    keys =
      case socket.assigns.trading_costs_missing do
        [_ | _] = missing -> missing
        [] -> all_cost_candidates(socket)
      end

    if keys == [] or socket.assigns.trading_costs_loading do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:trading_costs_loading, true)
       |> assign(
         :trading_positions_state,
         DataState.loading(socket.assigns.trading_positions,
           as_of: socket.assigns.trading_positions_state.as_of,
           source: :tax_lots
         )
       )
       |> start_async(:trading_costs, fn ->
         Enum.map(keys, &{&1, Portfolio.refresh_costs(&1)})
       end)}
    end
  end

  def handle_event("trading_retry_detail", _params, socket) do
    # Drop the error first: maybe_load_detail/1 leaves an in-flight run alone,
    # and a cleared error is what makes the panel show "Loading…" again.
    {:noreply, socket |> assign(:trading_detail, nil) |> maybe_load_detail()}
  end

  def handle_event("trading_select_account", %{"id" => id}, socket) do
    if valid_account_selection?(socket, id) do
      {:noreply,
       socket
       |> assign(:trading_account_sel, id)
       |> maybe_load_detail()
       |> load_anomaly()
       |> load_chart()}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Chat stream (from the conversation's PubSub broadcasts)
  # ---------------------------------------------------------------------------

  # Every conversation keeps its own state whether or not its window is open, so
  # a run started and then closed still has its transcript waiting when the
  # window comes back. Broadcasts are applied by conversation, never by "the
  # active one".
  @impl true
  def handle_info({:agent_chat, conv_id, payload}, socket) do
    if known_tab?(socket, conv_id),
      do: {:noreply, apply_chat(socket, conv_id, payload)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_chat(socket, conv, {:status, status}) do
    socket =
      socket
      |> put_chat(conv, fn c ->
        %{
          c
          | running: status == :running,
            thinking: if(status == :running, do: :running, else: nil)
        }
      end)
      |> update_tab(conv, &%{&1 | running: status == :running})

    # Only a Robinhood run may have moved money. Chart Build must remain a
    # zero-broker-run surface when its conversations finish.
    if status == :idle and tab_kind(socket, conv) == "robinhood",
      do: maybe_refresh_account(socket),
      else: socket
  end

  defp apply_chat(socket, conv, {:thinking, ms}),
    do: put_chat(socket, conv, &%{&1 | thinking: {:done, ms}})

  defp apply_chat(socket, conv, {:queue, items}),
    do: put_chat(socket, conv, &%{&1 | queue: items})

  defp apply_chat(socket, conv, {:message, %{role: :assistant, text: text}})
       when is_binary(text) do
    if tab_kind(socket, conv) == "chartbuild" do
      {clean, svgs} = SvgViewer.extract(text)
      # The datareq fence is stripped from the same text the SVG fence was, so
      # the operator reads prose rather than the request machinery — exactly how
      # the ```svg channel already behaves.
      {clean, requests} = DataReq.extract(clean)
      base = chat_state(socket.assigns, conv).svg_seq

      socket = collect_chart_svgs(socket, conv, svgs)
      svg_ids = svg_ids_for(base, svgs)

      socket =
        cond do
          clean != "" ->
            socket
            |> maybe_speak(conv, :assistant, clean)
            |> push_msg_to(conv, :assistant, clean, svg_ids)

          svgs != [] ->
            push_msg_to(socket, conv, :assistant, "", svg_ids)

          true ->
            socket
        end

      socket
      |> serve_datareq(conv, requests)
      |> maybe_flag_unread(conv, :assistant)
    else
      socket
      |> maybe_speak(conv, :assistant, text)
      |> push_msg_to(conv, :assistant, text)
      |> maybe_propose_order(conv, :assistant, text)
      |> maybe_flag_unread(conv, :assistant)
    end
  end

  defp apply_chat(socket, conv, {:message, %{role: role, text: text} = msg}) do
    socket
    |> maybe_speak(conv, role, text)
    # `:delivery` rides through so a steered bubble can say so — same contract
    # as Home's projection.
    |> push_msg_to(conv, role, text, [], Map.get(msg, :delivery))
    |> maybe_propose_order(conv, role, text)
    |> maybe_flag_unread(conv, role)
  end

  defp apply_chat(socket, _conv, _other), do: socket

  # A window that is closed or collapsed cannot be read, so its tab carries the
  # dot instead. An open, expanded window is already showing the message.
  defp maybe_flag_unread(socket, _conv, :user), do: socket

  defp maybe_flag_unread(socket, conv, _role) do
    # Collapsed cuts both ways: a Chart Build chat is only "already showing the
    # message" while its body is open. Collapsed, it is as unreadable as a
    # minimised floating window and earns the same dot.
    collapsed? = MapSet.member?(socket.assigns.minimized, conv)

    visible_chart? =
      conv == socket.assigns.active_tab and tab_kind(socket, conv) == "chartbuild" and
        not collapsed?

    if visible_chart? or (conv in socket.assigns.open_chats and not collapsed?),
      do: socket,
      else: update_tab(socket, conv, &%{&1 | unread: true})
  end

  # An assistant turn carrying a fenced ```order block arms the confirm card.
  # Only the assistant's own turns are read: echoing the operator's text back
  # through the parser would let a pasted block arm the card without the model —
  # and without the parameter-gathering that is the point of asking it.
  defp maybe_propose_order(socket, conv, :assistant, text) do
    case BusterClaw.TradingOrder.parse(text) do
      {:ok, order} ->
        # A money moment waiting on the operator gets a sound (SOUND_ROADMAP
        # group A, the one key with no broadcast of its own). Through the
        # SoundBoard's direct lane, so it passes the same master-switch /
        # cooldown / routing gates as every other chime.
        arm_or_refuse(socket, conv, order)

      :none ->
        socket

      {:error, reason} ->
        push_msg_to(
          socket,
          conv,
          :error,
          "The assistant proposed an order Buster Claw would not read: #{order_error(reason)}. " <>
            "Nothing was sent. Ask it to restate the order."
        )
    end
  end

  defp maybe_propose_order(socket, _conv, _role, _text), do: socket

  # Only an agent-enabled account can take an order, so a proposal naming any
  # other one is refused HERE rather than at the broker. Otherwise the operator
  # reads a card, clicks confirm, waits out a run, and gets a rejection for a
  # reason the app knew before it ever drew the card.
  defp arm_or_refuse(socket, conv, order) do
    case account_orderability(socket, order.account_last4) do
      :ok ->
        # A money moment waiting on the operator gets a sound (SOUND_ROADMAP
        # group A, the one key with no broadcast of its own). Through the
        # SoundBoard's direct lane, so it passes the same master-switch /
        # cooldown / routing gates as every other chime.
        BusterClaw.Notifications.SoundBoard.ring("order")
        put_chat(socket, conv, &%{&1 | pending_order: {:proposed, order}})

      {:refused, message} ->
        push_msg_to(socket, conv, :error, message)
    end
  end

  defp account_orderability(socket, last4) do
    accounts =
      socket.assigns.trading_account
      |> last_snapshot()
      |> Trading.accounts()

    cond do
      # No snapshot yet: we genuinely do not know, and blocking on our own
      # ignorance would make ordering depend on the dashboard having loaded.
      # The broker still gets the final say.
      accounts == [] ->
        :ok

      Enum.any?(accounts, &(&1["last4"] == last4 and &1["agentic"])) ->
        :ok

      Enum.any?(accounts, &(&1["last4"] == last4)) ->
        {:refused,
         "Account ••••#{last4} is not agent-enabled, so Robinhood will not accept an order " <>
           "for it. Nothing was sent. #{orderable_hint(accounts)}"}

      true ->
        {:refused,
         "No account ending #{last4} is on your latest snapshot, so Buster Claw will not " <>
           "send an order for it. Nothing was sent. #{orderable_hint(accounts)}"}
    end
  end

  defp orderable_hint(accounts) do
    case Enum.filter(accounts, & &1["agentic"]) do
      [] ->
        "None of your accounts are currently marked agent-enabled."

      agentic ->
        "Orders can be placed from: " <>
          Enum.map_join(agentic, ", ", &"#{&1["label"]} ••••#{&1["last4"]}") <> "."
    end
  end

  # Speak the model's replies aloud (client gates on the Voice toggle + desktop
  # app). Only `:assistant` text — never tool/meta/error lines.
  # Only the focused window speaks. Three conversations narrating at once over
  # each other is worse than silence from two of them.
  defp maybe_speak(socket, conv, :assistant, text) do
    if conv == List.last(socket.assigns.open_chats),
      do: push_event(socket, "bc:speak", %{text: text}),
      else: socket
  end

  defp maybe_speak(socket, _conv, _role, _text), do: socket

  # See `StatusLive.delivery_param/1` — same three values, same safe default.
  # Anything unrecognised reads as `:auto`, which can start a turn or queue but
  # can never claim to have steered.
  defp delivery_param(%{"delivery" => "steer"}), do: :steer
  defp delivery_param(%{"delivery" => "next"}), do: :next
  defp delivery_param(_params), do: :auto

  defp dispatch_chat(socket, conv_id, text, delivery) do
    # Trading requires the Claude CLI specifically: the MCP flags in
    # Trading.chat_opts/0 are Claude's, and codex would choke on them.
    case BusterClaw.AgentRunner.detect() do
      {:ok, {:claude, _path}} ->
        # One audit line per money-adjacent send. Length only — the full text
        # already persists in the conversation transcript.
        BusterClaw.Sentinel.observe(:outbound_send, "Trading chat message sent", %{
          source: "trading_chat",
          conv_id: conv_id,
          chars: String.length(text)
        })

        # The kind decides the toolset: a Chart Build window must never be
        # started with the broker's options just because it shares this
        # dispatcher.
        # The harness is resolved HERE, not inside Chat: a LiveView has DB
        # access and `Chat` deliberately does not read Settings (its own tests
        # run async with no sandbox).
        Chat.ensure_started(
          conv_id,
          Keyword.put(
            BusterClaw.Trading.ChatProfile.for_kind(tab_kind(socket, conv_id)),
            :agent,
            BusterClaw.ModelPolicy.backend_for(:chat)
          )
        )

        do_send(socket, conv_id, text, delivery)

      _other ->
        push_msg_to(socket, conv_id, :error, "Trading requires the Claude Code CLI.")
    end
  catch
    :exit, _reason ->
      push_msg_to(socket, conv_id, :error, "Chat backend isn't running — restart the server.")
  end

  # While a run is in flight send_message/2 queues the text (returns :ok) rather
  # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
  # The announcement is driven by the mode `submit/3` REPORTS, never the one the
  # composer asked for: a steer becomes `:queued` when the turn ended first, and
  # saying "steered" there would be the exact false-delivery this roadmap exists
  # to prevent.
  defp do_send(socket, conv_id, text, delivery) do
    case Chat.submit(conv_id, text, delivery: delivery) do
      {:ok, mode} ->
        assign(socket, :chat_announcement, announcement_for(mode, delivery))

      {:error, :no_agent_cli} ->
        socket

      {:error, reason} ->
        push_msg_to(socket, conv_id, :error, "Could not start the run: #{inspect(reason)}")
    end
  end

  defp announcement_for(:steered, _requested),
    do: "Steered. The agent will pick this up at its next step."

  defp announcement_for(:queued, :steer),
    do: "The turn finished first, so this was queued to run next."

  defp announcement_for(:queued, _requested), do: "Queued to run next."
  defp announcement_for(:started, _requested), do: "Sent."

  # Panel-side errors (a failed cost fetch, a crashed bar run) belong to whichever
  # conversation the operator is looking at, which is the active tab's.
  defp push_msg(socket, role, text),
    do: push_msg_to(socket, socket.assigns.active_tab, role, text)

  defp push_msg_to(socket, conv, role, text, svg_ids \\ [], delivery \\ nil) do
    put_chat(socket, conv, fn c ->
      seq = c.seq + 1
      msg = %{id: seq, role: role, text: text, svg_ids: svg_ids, delivery: delivery}

      %{
        c
        | seq: seq,
          messages:
            Enum.take(c.messages ++ [{"chat-msg-#{conv}-#{seq}", msg}], -@max_chat_messages)
      }
    end)
  end

  # --- Per-conversation chat state ---

  defp initial_chat_state(conv_id, kind) do
    {messages, svgs} = load_history(conv_id, kind)

    %{
      messages: messages,
      seq: length(messages),
      running: Chat.running?(conv_id),
      steerable: :steer in Chat.capabilities(conv_id).modes,
      thinking: if(Chat.running?(conv_id), do: :running, else: nil),
      queue: Chat.queue(conv_id),
      pending_order: nil,
      svgs: svgs,
      svg_seq: length(svgs),
      zoomed_id: nil,
      datareq_budget: @datareq_budget,
      datareq_seen: %{}
    }
  end

  defp chat_state(assigns_or_socket, conv) do
    Map.get(assigns_or_socket.chats, conv) || empty_chat_state()
  end

  defp empty_chat_state,
    do: %{
      messages: [],
      seq: 0,
      running: false,
      steerable: false,
      thinking: nil,
      queue: [],
      pending_order: nil,
      svgs: [],
      svg_seq: 0,
      zoomed_id: nil,
      datareq_budget: @datareq_budget,
      datareq_seen: %{}
    }

  defp put_chat(socket, conv, fun) do
    update(socket, :chats, fn chats ->
      Map.put(chats, conv, fun.(Map.get(chats, conv) || empty_chat_state()))
    end)
  end

  defp tab_kind(socket, conv), do: tab_kind_of(socket.assigns.tabs, conv)

  @history_roles %{
    "user" => :user,
    "assistant" => :assistant,
    "tool" => :tool,
    "meta" => :meta,
    "error" => :error
  }
  defp history_role(role), do: Map.get(@history_roles, role, :assistant)

  # Restore the transcript from persisted history. Chart Build extracts and
  # sanitizes its SVG blocks back into the preview bank; every other kind keeps
  # the historical trading behavior and renders plain text.
  # --- Tab helpers ---

  defp to_tab(conv),
    do: %{
      id: conv.id,
      title: conv.title,
      kind: conv.kind,
      docked: conv.docked,
      running: false,
      unread: false
    }

  defp docked?(tabs, conv) do
    case Enum.find(tabs, &(&1.id == conv)) do
      nil -> false
      tab -> tab.docked
    end
  end

  defp known_tab?(socket, id), do: Enum.any?(socket.assigns.tabs, &(&1.id == id))

  defp tab_title(tabs, conv) do
    case Enum.find(tabs, &(&1.id == conv)) do
      nil -> "Chat"
      tab -> tab.title
    end
  end

  defp tab_kind_of(tabs, conv) do
    case Enum.find(tabs, &(&1.id == conv)) do
      nil -> "robinhood"
      tab -> tab.kind
    end
  end

  defp active_tab_kind(socket) do
    case Enum.find(socket.assigns.tabs, &(&1.id == socket.assigns.active_tab)) do
      nil -> "robinhood"
      tab -> tab.kind
    end
  end

  # Switching tabs swaps the PANEL and nothing else. Open chat windows are
  # deliberately untouched: they float above whichever panel is showing, and a
  # run in one conversation is not interrupted by looking at another's data.
  defp activate_tab(socket, id) do
    Conversations.touch(id)
    kind = tab_kind(socket, id)

    socket
    |> assign(:active_tab, id)
    |> update(:chats, fn chats ->
      Map.put_new_lazy(chats, id, fn -> initial_chat_state(id, kind) end)
    end)
    |> then(&assign(&1, :active_kind, active_tab_kind(&1)))
  end

  defp update_tab(socket, id, fun) do
    tabs = Enum.map(socket.assigns.tabs, fn t -> if t.id == id, do: fun.(t), else: t end)
    assign(socket, :tabs, tabs)
  end

  defp close_tab(socket, id) do
    Chat.stop(id)
    Conversations.close(id)
    if connected?(socket), do: Phoenix.PubSub.unsubscribe(BusterClaw.PubSub, Chat.topic(id))

    remaining = Enum.reject(socket.assigns.tabs, &(&1.id == id))

    socket =
      socket
      |> update(:lookup, &Map.delete(&1, id))
      |> update(:chats, &Map.delete(&1, id))
      |> assign(:open_chats, List.delete(socket.assigns.open_chats, id))
      |> update(:minimized, &MapSet.delete(&1, id))

    cond do
      # The page is a tab strip; an empty one has nothing to render into.
      remaining == [] ->
        {:ok, conv} = Conversations.create(%{title: "Robinhood", kind: "robinhood"})
        if connected?(socket), do: Chat.subscribe(conv.id)
        socket |> assign(:tabs, [to_tab(conv)]) |> activate_tab(conv.id)

      socket.assigns.active_tab == id ->
        socket |> assign(:tabs, remaining) |> activate_tab(hd(remaining).id)

      true ->
        assign(socket, :tabs, remaining)
    end
  end

  # --- The datareq channel (CHART_BUILD_WEB_DATA_ROADMAP Phase 2) ---
  #
  # Chart Build may search the web but may not plot what it reads there. When it
  # needs figures it emits a ```datareq block; the app fetches them through a
  # real adapter and delivers them as the NEXT TURN. A turn, not a restarted
  # process with a fresh system prompt, because `Chat.ensure_started/2` captures
  # its options once and the --resume session id dies with the process —
  # re-injecting any other way would discard the conversation that just made the
  # request.

  defp serve_datareq(socket, _conv, []), do: socket

  defp serve_datareq(socket, conv, [request | extra]) do
    socket
    |> deliver_datareq(conv, request)
    |> note_extra_datareqs(conv, extra)
  end

  # A request the app will not even attempt — unknown source, no series, bad
  # JSON. Refused without spending budget: nothing was fetched, so nothing was
  # spent, and the model still gets told why.
  defp deliver_datareq(socket, conv, {:invalid, _reason} = invalid),
    do: send_datareq_turn(socket, conv, DataReq.refuse(invalid))

  defp deliver_datareq(socket, conv, request) do
    chat = chat_state(socket.assigns, conv)
    signature = DataReq.signature(request)

    cond do
      chat.datareq_budget <= 0 ->
        send_datareq_turn(socket, conv, DataReq.refuse_budget())

      # Asked twice, failed twice, identically. A third attempt cannot succeed,
      # and the model rephrasing the same impossible request is precisely the
      # loop the budget is a backstop for.
      Map.get(chat.datareq_seen, signature, 0) >= 2 ->
        send_datareq_turn(socket, conv, DataReq.refuse_repeat(signature))

      true ->
        run_datareq(socket, conv, request, signature)
    end
  end

  defp run_datareq(socket, conv, request, signature) do
    result = DataReq.fulfill(request, datareq_opts())

    # One audit line per fetch. Sentinel cannot see the CLI's own WebSearch (see
    # docs/LOCAL_TRUST.md), so this path — the one that produces PLOTTABLE
    # numbers — is the one that must be visible.
    BusterClaw.Sentinel.observe(:untrusted_ingest, "Chart Build data fetch", %{
      conv_id: conv,
      source: request.source,
      series: request.series,
      outcome: if(match?({:ok, _payload}, result), do: "ok", else: "error")
    })

    socket
    |> put_chat(conv, fn chat ->
      %{
        chat
        | datareq_budget: chat.datareq_budget - 1,
          datareq_seen: bump_failure(chat.datareq_seen, signature, result)
      }
    end)
    |> send_datareq_turn(conv, DataReq.deliver(result))
  end

  # Only FAILURES count toward the repeat brake. Asking for the same series
  # again after a success is a legitimate thing to do (a wider window, say).
  defp bump_failure(seen, _signature, {:ok, _payload}), do: seen

  defp bump_failure(seen, signature, {:error, _reason}),
    do: Map.update(seen, signature, 1, &(&1 + 1))

  defp note_extra_datareqs(socket, _conv, []), do: socket

  defp note_extra_datareqs(socket, conv, extra),
    do: send_datareq_turn(socket, conv, DataReq.refuse_extra(length(extra)))

  # The delivery is a real user-role turn: it goes into the transcript where the
  # operator can see exactly what the app handed the model. `send_message/2`
  # queues while the current run is in flight, so this lands as the next turn
  # rather than racing it.
  defp send_datareq_turn(socket, conv, text) do
    Chat.send_message(conv, text)
    push_msg_to(socket, conv, :user, text)
  catch
    :exit, _reason ->
      push_msg_to(socket, conv, :error, "Data delivery failed — the chat backend isn't running.")
  end

  defp datareq_opts, do: Application.get_env(:buster_claw, :datareq_opts, [])

  defp reset_datareq_budget(socket, conv) do
    if tab_kind(socket, conv) == "chartbuild" do
      put_chat(socket, conv, &%{&1 | datareq_budget: @datareq_budget, datareq_seen: %{}})
    else
      socket
    end
  end

  # --- Lookup helpers ---

  defp put_lookup(socket, panel),
    do: update(socket, :lookup, &Map.put(&1, socket.assigns.active_tab, panel))

  defp lookup_panel(socket_or_assigns) do
    Map.get(socket_or_assigns.lookup, socket_or_assigns.active_tab) || Fetch.blank()
  end

  defp load_history(conv_id, "chartbuild") do
    {messages_rev, charts_rev, _next_chart} =
      conv_id
      |> AgentTranscript.recent(limit: 200)
      |> Enum.reduce({[], [], 1}, fn row, {messages, charts, next_chart} ->
        role = history_role(row.role)
        {text, drawings} = chart_history_content(role, row.content)
        ids = chart_ids(next_chart, length(drawings))

        charts =
          Enum.reduce(Enum.zip(ids, drawings), charts, fn {id, svg}, acc ->
            [%{id: id, svg: svg} | acc]
          end)

        if text == "" and drawings == [] do
          {messages, charts, next_chart}
        else
          {[%{role: role, text: text, svg_ids: ids} | messages], charts,
           next_chart + length(drawings)}
        end
      end)

    messages =
      messages_rev
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {message, i} ->
        {"chat-msg-#{conv_id}-#{i}", Map.put(message, :id, i)}
      end)

    {messages, charts_rev |> Enum.reverse() |> Enum.take(-@max_chat_svgs)}
  end

  defp load_history(conv_id, _kind) do
    messages =
      conv_id
      |> AgentTranscript.recent(limit: 200)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, i} ->
        {"chat-msg-#{conv_id}-#{i}",
         %{id: i, role: history_role(row.role), text: row.content, svg_ids: []}}
      end)

    {messages, []}
  end

  defp chart_history_content(:assistant, content) do
    {clean, svgs} = SvgViewer.extract(content)
    {clean, Enum.map(svgs, &sanitize_chart/1)}
  end

  defp chart_history_content(_role, content), do: {content, []}

  defp chart_ids(_next, 0), do: []
  defp chart_ids(next, count), do: Enum.to_list(next..(next + count - 1))

  defp svg_ids_for(_base, []), do: []
  defp svg_ids_for(base, svgs), do: Enum.to_list((base + 1)..(base + length(svgs)))

  defp collect_chart_svgs(socket, _conv, []), do: socket

  defp collect_chart_svgs(socket, conv, svgs) do
    put_chat(socket, conv, fn chat ->
      new =
        svgs
        |> Enum.with_index(chat.svg_seq + 1)
        |> Enum.map(fn {svg, id} -> %{id: id, svg: sanitize_chart(svg)} end)

      %{
        chat
        | svgs: Enum.take(chat.svgs ++ new, -@max_chat_svgs),
          svg_seq: chat.svg_seq + length(svgs)
      }
    end)
  end

  defp sanitize_chart(svg), do: svg |> SvgViewer.sanitize() |> SvgViewer.normalize()

  defp active_charts(assigns), do: chat_state(assigns, assigns.active_tab).svgs

  defp chart_zoom_step(socket, dir) do
    conv = socket.assigns.active_tab

    put_chat(socket, conv, fn chat ->
      case Enum.find_index(chat.svgs, &(&1.id == chat.zoomed_id)) do
        nil ->
          chat

        index ->
          next =
            case dir do
              "prev" -> max(index - 1, 0)
              "next" -> min(index + 1, length(chat.svgs) - 1)
              _other -> index
            end

          %{chat | zoomed_id: Enum.at(chat.svgs, next).id}
      end
    end)
  end

  defp transition_chartbuild_layout(socket, id, _previous, "chartbuild") do
    {:ok, _conv} = Conversations.set_docked(id, false)

    socket
    |> update_tab(id, &%{&1 | docked: false})
    |> assign(:open_chats, List.delete(socket.assigns.open_chats, id))
    |> update(:minimized, &MapSet.delete(&1, id))
  end

  defp transition_chartbuild_layout(socket, id, "chartbuild", kind) do
    docked = kind == "chat"
    {:ok, _conv} = Conversations.set_docked(id, docked)

    open_chats =
      if docked,
        do: List.delete(socket.assigns.open_chats, id),
        else: Enum.uniq(socket.assigns.open_chats ++ [id])

    socket
    |> update_tab(id, &%{&1 | docked: docked})
    |> assign(:open_chats, open_chats)
    # Retyping away carries no collapse with it: `minimized` is shared with the
    # floating windows, so a chat left collapsed here would otherwise re-open
    # as a minimised window somewhere else on the tab.
    |> update(:minimized, &MapSet.delete(&1, id))
  end

  defp transition_chartbuild_layout(socket, _id, _previous, _kind), do: socket

  # ---------------------------------------------------------------------------
  # Account snapshot / chart / detail asyncs
  # ---------------------------------------------------------------------------

  @impl true
  def handle_async(:trading_account, {:ok, result}, socket) do
    case result do
      {:ok, snap} ->
        Trading.store_snapshot(snap)

        # Every stage-1 reading also lands in the durable ledger. Robinhood keeps
        # no value history, so a reading we don't record is a day that never
        # existed — recording is best-effort and must never break the panel.
        record_portfolio(snap)

        {:noreply,
         socket
         |> assign(:trading_account, {:ok, snap})
         |> reconcile_account_selection()
         |> maybe_load_detail()
         |> load_anomaly()
         |> load_chart()}

      {:error, reason} ->
        # Keep the last good snapshot visible under the error line.
        prev = last_snapshot(socket.assigns.trading_account)
        {:noreply, assign(socket, :trading_account, {:error, reason, prev})}
    end
  end

  # A crashed fetch task degrades to the error state — never a stalled panel.
  def handle_async(:trading_account, {:exit, reason}, socket) do
    prev = last_snapshot(socket.assigns.trading_account)
    {:noreply, assign(socket, :trading_account, {:error, {:exit, reason}, prev})}
  end

  def handle_async(:trading_backfill, {:ok, results}, socket) do
    failed = for {key, {:error, reason}} <- results, do: {key, reason}

    socket =
      socket
      |> assign(:trading_backfilling, false)
      |> load_chart()

    # A backfill that failed says so. Silently leaving the coverage warning up
    # would read as "still loading" forever.
    if failed == [] do
      {:noreply, socket}
    else
      {:noreply,
       push_msg(socket, :error, "Couldn't load history for #{length(failed)} account(s).")}
    end
  end

  def handle_async(:trading_backfill, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:trading_backfilling, false)
     |> push_msg(:error, "The history fetch crashed.")}
  end

  def handle_async({:symbol_bars, symbol, interval, requested_from}, {:ok, result}, socket) do
    handle_symbol_bars_result(symbol, interval, requested_from, result, socket)
  end

  def handle_async({:symbol_bars, symbol, interval, requested_from}, {:exit, _reason}, socket) do
    request = {symbol, interval, requested_from}

    {:noreply,
     socket
     |> finish_symbol_request(request)
     |> mark_symbol_failure(request, :task_exit)
     |> push_msg(:error, "The #{symbol} bar fetch crashed.")
     |> maybe_fetch_current_symbol_after(request)}
  end

  def handle_async(:trading_costs, {:ok, results}, socket) do
    failed = for {key, {:error, reason}} <- results, do: {key, reason}

    socket =
      socket
      |> assign(:trading_costs_loading, false)
      |> load_positions()

    if failed == [] do
      {:noreply, socket}
    else
      {:noreply,
       push_msg(socket, :error, "Couldn't load cost basis for #{length(failed)} account(s).")}
    end
  end

  def handle_async(:trading_costs, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:trading_costs_loading, false)
     |> push_msg(:error, "The cost-basis fetch crashed.")}
  end

  # The submit run came back. Whatever it says, the card settles here and offers
  # no retry — see the double-submission note in BusterClaw.TradingOrder.
  def handle_async({:trading_order, conv}, {:ok, result}, socket) do
    {:noreply, settle_order(socket, conv, result)}
  end

  # A crashed submit is exactly the unknown case: the run died, and nothing here
  # can tell whether the broker took the order before it did.
  def handle_async({:trading_order, conv}, {:exit, _reason}, socket) do
    {:noreply, settle_order(socket, conv, {:error, :unknown})}
  end

  # Stage 2 lands. The id is carried through the result rather than read off the
  # socket: the user may have clicked another chip while this ran, and the data
  # belongs to the account that was asked for, not the one now on screen.
  def handle_async({:trading_detail, id}, {:ok, result}, socket) do
    case result do
      {:ok, detail} ->
        {:noreply,
         socket
         |> store_detail(id, detail)
         |> maybe_load_current_after_detail(id)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:trading_detail, {:error, id, reason})
         |> maybe_load_current_after_detail(id)}
    end
  end

  def handle_async({:trading_detail, id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:trading_detail, {:error, id, {:exit, reason}})
     |> maybe_load_current_after_detail(id)}
  end

  defp handle_symbol_bars_result(symbol, interval, requested_from, result, socket) do
    request = {symbol, interval, requested_from}
    socket = finish_symbol_request(socket, request)

    case result do
      {:ok, rows} ->
        BusterClaw.MarketData.store_ohlc(symbol, interval, rows)

        {:noreply,
         socket
         |> load_symbol_bars()
         |> mark_symbol_empty(request, rows)
         |> maybe_fetch_current_symbol_after(request)}

      {:error, reason} ->
        {:noreply,
         socket
         |> mark_symbol_failure(request, reason)
         |> push_msg(:error, "Couldn't fetch #{symbol} bars: #{bars_error(reason)}")
         |> maybe_fetch_current_symbol_after(request)}
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshot / chart / detail helpers
  # ---------------------------------------------------------------------------

  defp assign_cached_snapshot(socket) do
    case Trading.cached_snapshot() do
      {:ok, snap} -> assign(socket, :trading_account, {:ok, snap})
      :none -> socket
    end
  end

  # Show whatever snapshot is cached immediately; refresh only when missing or
  # stale — every refresh is a real (haiku) agent run, cents not free.
  defp load_trading_account(socket) do
    case Trading.cached_snapshot() do
      {:ok, snap} ->
        socket = assign(socket, :trading_account, {:ok, snap})
        socket = load_chart(socket)

        if Trading.snapshot_stale?(snap),
          do: maybe_refresh_account(socket),
          else: socket |> maybe_load_detail() |> load_anomaly()

      :none ->
        socket |> load_chart() |> maybe_refresh_account()
    end
  end

  # One in-flight refresh max; the last good snapshot stays visible while a
  # fresh one loads (or fails — see handle_async).
  defp maybe_refresh_account(socket) do
    case socket.assigns.trading_account do
      {:loading, _prev} ->
        socket

      current ->
        socket
        |> assign(:trading_account, {:loading, last_snapshot(current)})
        |> start_async(:trading_account, fn -> Trading.fetch_account_snapshot() end)
    end
  end

  # The "All" chip is a selection the snapshot has no account for, so it is
  # answered here rather than inside Trading.select_account/2 — which would
  # otherwise fall back to the agentic account and quietly chart the wrong thing.
  defp selected_account_key(%{assigns: %{trading_account_sel: @all_accounts}}),
    do: {:error, :all_accounts}

  defp selected_account_key(socket) do
    snap = last_snapshot(socket.assigns.trading_account)
    account = snap && Trading.select_account(snap, socket.assigns.trading_account_sel)

    case account && Trading.account_key(account) do
      nil -> {:error, :no_account}
      key -> {:ok, key}
    end
  end

  # The sign lives with the kind, so the form only ever collects a magnitude —
  # a user typing "-500" for a withdrawal must not end up with a double negative.
  defp flow_cents("not_a_transfer", _amount), do: {:ok, 0}

  defp flow_cents(kind, amount) when kind in ["deposit", "withdrawal"] do
    case Float.parse(to_string(amount || "")) do
      {dollars, rest} when dollars > 0 ->
        if String.trim(rest) == "" do
          cents = round(dollars * 100)
          {:ok, if(kind == "withdrawal", do: -cents, else: cents)}
        else
          {:error, :bad_amount}
        end

      _other ->
        {:error, :bad_amount}
    end
  end

  defp flow_cents(_kind, _amount), do: {:error, :bad_kind}

  # The panel asks about the selected account's most recent unexplained move —
  # or, on the combined view, about any account's, since a prompt nobody can
  # reach is a prompt that never gets answered.
  defp load_anomaly(socket) do
    anomaly =
      case selected_account_key(socket) do
        {:ok, key} -> Portfolio.latest_anomaly(key)
        {:error, :all_accounts} -> Portfolio.latest_anomaly_across(ledger_keys(socket))
        {:error, _} -> nil
      end

    assign(socket, :trading_anomaly, anomaly)
  end

  defp ledger_keys(socket) do
    socket.assigns.trading_account
    |> last_snapshot()
    |> Trading.accounts()
    |> Enum.map(&Trading.account_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp valid_account_selection?(_socket, @all_accounts), do: true

  defp valid_account_selection?(socket, id) when is_binary(id) do
    socket.assigns.trading_account
    |> last_snapshot()
    |> Trading.accounts()
    |> Enum.any?(&(&1["id"] == id))
  end

  defp valid_account_selection?(_socket, _id), do: false

  # The chart's series follows the chip: the combined total, or one account.
  defp load_chart(socket) do
    series =
      case selected_account_key(socket) do
        {:ok, key} -> Portfolio.cumulative_series(key)
        {:error, :all_accounts} -> Portfolio.total_cumulative_series()
        {:error, _} -> []
      end

    socket
    |> assign(:trading_series, series)
    |> assign(:trading_performance_state, performance_state(series))
    |> assign(:trading_coverage, Portfolio.backfill_coverage())
    # The hero recomputes with the chart: both read the ledger, and a flow or
    # exclusion that moves one must move the other in the same render.
    |> assign(:trading_day_change, Portfolio.total_day_change())
    |> assign(:market_indexes_state, BusterClaw.MarketData.index_state())
    |> load_positions()
    |> maybe_default_range(series)
  end

  defp performance_state([]),
    do: DataState.unavailable(:no_readings, source: :portfolio_ledger)

  defp performance_state(series) do
    as_of = series |> List.last() |> Map.fetch!(:day)

    latest_market_day =
      BusterClaw.MarketCalendar.latest_trading_day(BusterClaw.MarketCalendar.today())

    DataState.cached(
      series,
      Date.compare(as_of, latest_market_day) == :lt,
      as_of: as_of,
      source: :portfolio_ledger
    )
  end

  # The positions panel (Phase 3): cost rows joined with cached prices and
  # sparkline closes — ALL of it from SQLite/Settings, zero agent runs on
  # render. The only run this panel can cause is the explicit Load/Refresh.
  @spark_lookback_days 30

  defp load_positions(socket) do
    earnings_state =
      BusterClaw.MarketData.earnings_state(BusterClaw.MarketCalendar.today())

    rows =
      Portfolio.position_rows()
      |> Enum.map(&display_position/1)
      |> Enum.sort_by(&(-(&1.value_cents || 0)))

    candidates = all_cost_candidates(socket)
    missing = costs_missing(socket)

    socket
    |> assign(:trading_positions, rows)
    |> assign(:trading_positions_state, positions_state(rows, candidates, missing))
    |> assign(:trading_costs_missing, missing)
    |> assign(:prices_state, aggregate_price_state(rows))
    |> assign(:trading_earnings_state, earnings_state)
    |> assign(:trading_earnings, state_data(earnings_state))
  end

  # Rows we have are rows we have: a partial load is `cached`, not `unavailable`.
  # Marking the dataset unavailable while handing it real data put the words
  # "Holdings: unavailable" directly above a populated holdings table. Which
  # accounts are still missing is a separate fact, and `costs_missing` already
  # says it in its own sentence under the header.
  defp positions_state([_ | _] = rows, _candidates, _missing) do
    as_of = oldest_position_at(rows)

    DataState.cached(rows, datetime_stale?(as_of), as_of: as_of, source: :tax_lots)
  end

  defp positions_state([], _candidates, [_ | _]),
    do: DataState.unavailable(:not_loaded, source: :tax_lots)

  defp positions_state([], [], []),
    do: DataState.unavailable(:no_supported_accounts, source: :tax_lots)

  defp positions_state([], candidates, []) do
    as_of =
      candidates
      |> Enum.map(&Portfolio.costs_refreshed_at/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        dates -> Enum.min(dates, DateTime)
      end

    if datetime_stale?(as_of) do
      DataState.stale([], as_of: as_of, source: :tax_lots)
    else
      DataState.confirmed_empty(as_of: as_of, source: :tax_lots)
    end
  end

  defp oldest_position_at(rows), do: rows |> Enum.map(& &1.as_of) |> Enum.min(DateTime)

  defp allowed_symbols(socket) do
    position_symbols = Enum.map(socket.assigns.trading_positions, & &1.symbol)
    earnings_symbols = Enum.map(socket.assigns.trading_earnings, & &1.symbol)
    position_symbols ++ earnings_symbols
  end

  defp display_position(row) do
    price_state = BusterClaw.MarketData.price_state_for(row.symbol)
    price_info = price_state.data || %{}
    price_cents = price_info[:price_cents]

    value_cents = price_cents && round(row.quantity * price_cents)

    unrealized_cents =
      if value_cents && row.cost_basis_cents, do: value_cents - row.cost_basis_cents

    row
    |> Map.merge(%{
      price_state: price_state,
      price_cents: price_cents,
      day_change_pct: price_info[:change_pct],
      value_cents: value_cents,
      unrealized_cents: unrealized_cents,
      unrealized_pct:
        if(unrealized_cents && row.cost_basis_cents > 0,
          do: unrealized_cents / row.cost_basis_cents * 100
        ),
      closes:
        BusterClaw.MarketData.bars(row.symbol, @spark_lookback_days)
        |> Enum.map(& &1.close_cents)
    })
  end

  defp aggregate_price_state([]),
    do: DataState.unavailable(:no_positions, source: :position_prices)

  defp aggregate_price_state(rows) do
    states = Enum.map(rows, & &1.price_state)
    as_of = oldest_price_at(states)

    cond do
      Enum.any?(states, &(&1.status == :unavailable)) ->
        DataState.unavailable(:partial,
          data: states,
          as_of: as_of,
          source: :position_prices
        )

      Enum.any?(states, &(&1.status == :stale)) ->
        DataState.stale(states, as_of: as_of, source: :position_prices)

      true ->
        DataState.fresh(states, as_of: as_of, source: :position_prices)
    end
  end

  defp oldest_price_at(states) do
    dates = states |> Enum.map(& &1.as_of) |> Enum.reject(&is_nil/1)

    cond do
      dates == [] ->
        nil

      Enum.any?(dates, &match?(%Date{}, &1)) ->
        dates
        |> Enum.map(fn
          %DateTime{} = at -> DateTime.to_date(at)
          %Date{} = day -> day
        end)
        |> Enum.min(Date)

      true ->
        Enum.min(dates, DateTime)
    end
  end

  # Included, holdings-capable accounts with no cost rows yet — what the Load
  # button will spend runs on. Crypto accounts are never candidates: there is
  # no tax-lot tool to answer for them.
  defp costs_missing(socket) do
    socket.assigns.trading_account
    |> last_snapshot()
    |> Trading.accounts()
    |> Enum.filter(&(&1["holdings_supported"] and is_binary(Trading.account_key(&1))))
    |> Enum.map(&Trading.account_key/1)
    |> Portfolio.accounts_missing_costs()
  end

  # --- Symbol chart data (Phase 4) ---

  defp load_symbol_bars(%{assigns: %{trading_chart_view: {:symbol, symbol}}} = socket) do
    {days, interval} = symbol_window(socket.assigns.symbol_range)
    from = Date.add(BusterClaw.MarketCalendar.today(), -days)
    rows = BusterClaw.MarketData.chart_bars(symbol, interval, from)

    socket
    |> assign(:symbol_bars, rows)
    |> assign(:symbol_bars_state, symbol_bars_state(rows, interval))
  end

  defp load_symbol_bars(socket) do
    socket
    |> assign(:symbol_bars, [])
    |> assign(
      :symbol_bars_state,
      DataState.unavailable(:not_selected, source: :price_history)
    )
  end

  # Fetch only when the cache can't already answer. Line mode over the short
  # ranges rides the sweep's closes for free; candles (any range) and the deep
  # ranges need full OHLC the sweep never fetches.
  defp maybe_fetch_symbol_bars(%{assigns: %{trading_chart_view: {:symbol, symbol}} = a} = socket) do
    {days, interval} = symbol_window(a.symbol_range)
    today = BusterClaw.MarketCalendar.today()
    from = Date.add(today, -days)

    needs_full? = a.symbol_mode == :candles or a.symbol_range in ["1Y", "5Y"]

    cond do
      not needs_full? ->
        socket

      not is_nil(a.symbol_bars_request) ->
        assign(
          socket,
          :symbol_bars_state,
          DataState.loading(a.symbol_bars,
            as_of: socket.assigns.symbol_bars_state.as_of,
            reason: :waiting_for_active_request,
            source: :price_history
          )
        )

      BusterClaw.MarketData.chart_coverage?(symbol, interval, from, today) ->
        socket

      true ->
        request = {symbol, interval, from}

        socket
        |> assign(:symbol_bars_request, request)
        |> assign(
          :symbol_bars_state,
          DataState.loading(a.symbol_bars,
            as_of: socket.assigns.symbol_bars_state.as_of,
            source: :price_history
          )
        )
        |> start_async({:symbol_bars, symbol, interval, from}, fn ->
          Trading.fetch_symbol_bars(symbol, from, interval)
        end)
    end
  end

  defp maybe_fetch_symbol_bars(socket), do: socket

  defp maybe_fetch_current_symbol_after(socket, completed_request) do
    case current_symbol_request(socket) do
      nil -> socket
      ^completed_request -> socket
      _current_request -> maybe_fetch_symbol_bars(socket)
    end
  end

  defp finish_symbol_request(socket, request) do
    if socket.assigns.symbol_bars_request == request,
      do: assign(socket, :symbol_bars_request, nil),
      else: socket
  end

  defp mark_symbol_empty(socket, request, []) do
    if current_symbol_request(socket) == request and socket.assigns.symbol_bars == [] do
      assign(
        socket,
        :symbol_bars_state,
        DataState.confirmed_empty(as_of: DateTime.utc_now(), source: :price_history)
      )
    else
      socket
    end
  end

  defp mark_symbol_empty(socket, _request, _rows), do: socket

  defp mark_symbol_failure(socket, request, reason) do
    if current_symbol_request(socket) == request do
      state =
        case socket.assigns.symbol_bars do
          [] ->
            DataState.unavailable(reason, source: :price_history)

          rows ->
            DataState.stale(rows,
              as_of: socket.assigns.symbol_bars_state.as_of,
              reason: reason,
              source: :price_history
            )
        end

      assign(socket, :symbol_bars_state, state)
    else
      socket
    end
  end

  defp symbol_bars_state([], _interval),
    do: DataState.unavailable(:not_cached, source: :price_history)

  defp symbol_bars_state(rows, interval) do
    as_of = rows |> List.last() |> Map.fetch!(:bar_on)
    latest = BusterClaw.MarketCalendar.latest_trading_day(BusterClaw.MarketCalendar.today())

    # A catch-all, not two clauses: `symbol_window/1` returns only day/week
    # today, but an unmatched interval here would raise inside a render path —
    # a blank Trading tab because someone added a third window.
    stale? =
      case interval do
        "week" -> Date.compare(as_of, Date.add(latest, -7)) == :lt
        _day -> Date.compare(as_of, latest) == :lt
      end

    DataState.cached(rows, stale?, as_of: as_of, source: :price_history)
  end

  defp current_symbol_request(%{
         assigns: %{trading_chart_view: {:symbol, symbol}, symbol_range: range}
       }) do
    {days, interval} = symbol_window(range)
    from = Date.add(BusterClaw.MarketCalendar.today(), -days)
    {symbol, interval, from}
  end

  defp current_symbol_request(_socket), do: nil

  defp bars_error(:broker_tools_unavailable),
    do: "Robinhood tools unavailable — run `claude mcp login robinhood`"

  defp bars_error({:robinhood, msg}), do: msg
  defp bars_error(:bad_snapshot), do: "unreadable response"
  defp bars_error({:timeout, _}), do: "the run timed out"
  defp bars_error(other), do: inspect(other)

  defp all_cost_candidates(socket) do
    excluded = Portfolio.excluded_accounts()

    socket.assigns.trading_account
    |> last_snapshot()
    |> Trading.accounts()
    |> Enum.filter(&(&1["holdings_supported"] and is_binary(Trading.account_key(&1))))
    |> Enum.map(&Trading.account_key/1)
    |> Enum.reject(&(&1 in excluded))
  end

  defp maybe_default_range(%{assigns: %{trading_range_pinned: true}} = socket, _series),
    do: socket

  defp maybe_default_range(socket, series),
    do: assign(socket, :trading_range, BusterClawWeb.PortfolioChart.default_range(series))

  # Best-effort by construction: the ledger is a side effect of showing balances,
  # and a ledger failure must not cost the user the panel they asked for.
  defp record_portfolio(snap) do
    case Portfolio.record(snap) do
      {:ok, _count} -> :ok
      {:error, reason} -> Logger.warning("Portfolio: recording skipped: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("Portfolio: recording raised: #{inspect(error)}")
  end

  defp reconcile_account_selection(socket) do
    if valid_account_selection?(socket, socket.assigns.trading_account_sel) do
      socket
    else
      socket
      |> assign(:trading_account_sel, @all_accounts)
      |> assign(:trading_detail, nil)
    end
  end

  # Stage 2, on demand: fetch the selected account's holdings only if they
  # aren't already loaded, the account can be read at all (crypto can't), and
  # nothing is already in flight for it. Selecting a chip whose detail is
  # cached costs nothing.
  defp maybe_load_detail(%{assigns: %{trading_account_sel: @all_accounts}} = socket), do: socket

  defp maybe_load_detail(socket) do
    snap = last_snapshot(socket.assigns.trading_account)
    account = snap && Trading.select_account(snap, socket.assigns.trading_account_sel)

    cond do
      is_nil(account) ->
        socket

      not Trading.needs_detail?(account) ->
        # Already loaded (or unreadable): clear any stale error for this
        # account so a cached chip doesn't render a leftover failure.
        clear_detail_error(socket, account["id"])

      match?({:loading, _}, socket.assigns.trading_detail) ->
        socket

      is_nil(Trading.last4(account)) ->
        # No digits to match on — stage 2 has nothing to look the account up
        # by, so say so rather than launching a run that cannot succeed.
        assign(socket, :trading_detail, {:error, account["id"], :unidentifiable_account})

      is_nil(Trading.account_key(account)) ->
        assign(socket, :trading_detail, {:error, account["id"], :ambiguous_account})

      true ->
        id = account["id"]
        last4 = Trading.last4(account)

        socket
        |> assign(:trading_detail, {:loading, id})
        |> start_async({:trading_detail, id}, fn -> Trading.fetch_account_detail(last4) end)
    end
  end

  defp clear_detail_error(socket, id) do
    case socket.assigns.trading_detail do
      {:error, ^id, _reason} -> assign(socket, :trading_detail, nil)
      _ -> socket
    end
  end

  defp maybe_load_current_after_detail(socket, completed_id) do
    if socket.assigns.trading_account_sel == completed_id,
      do: socket,
      else: maybe_load_detail(socket)
  end

  # Merge stage 2 into the cached snapshot so the detail survives a remount,
  # exactly like the balances do.
  defp store_detail(socket, id, detail) do
    case last_snapshot(socket.assigns.trading_account) do
      nil ->
        assign(socket, :trading_detail, nil)

      snap ->
        merged = Trading.merge_detail(snap, id, detail)
        Trading.store_snapshot(merged)

        socket
        |> assign(:trading_account, put_snapshot(socket.assigns.trading_account, merged))
        |> assign(:trading_detail, nil)
    end
  end

  # Replace the snapshot inside whatever stage-1 state we're in, without
  # disturbing that state — a detail landing mid-refresh must not cancel the
  # spinner or clear an error line that is still true.
  defp put_snapshot({:ok, _prev}, snap), do: {:ok, snap}
  defp put_snapshot({:loading, _prev}, snap), do: {:loading, snap}
  defp put_snapshot({:error, reason, _prev}, snap), do: {:error, reason, snap}
  defp put_snapshot(_other, snap), do: {:ok, snap}

  defp chat_empty_message("chartbuild"),
    do:
      "Describe the chart you want. Use pasted figures or ask for your cached portfolio " <>
        "history and held-symbol closes; revisions appear in the preview above."

  defp chat_empty_message(_robinhood),
    do:
      "Portfolio assistant. Ask about balances, positions, order history, or market data — " <>
        "or ask it to buy or sell, and it will put the order up for your confirmation."

  defp chat_placeholder("chartbuild"),
    do: "Describe or revise the chart…  (Enter to send, Shift+Enter for a new line)"

  defp chat_placeholder(_robinhood),
    do: "Ask about your portfolio…  (Enter to send, Shift+Enter for a new line)"

  # ---------------------------------------------------------------------------
  # Order confirmation helpers
  # ---------------------------------------------------------------------------

  defp settle_order(socket, conv, result) do
    case chat_state(socket.assigns, conv) do
      %{pending_order: {:submitting, order}} -> do_settle_order(socket, conv, order, result)
      _other -> socket
    end
  end

  defp do_settle_order(socket, conv, order, result) do
    summary = BusterClaw.TradingOrder.summary(order)

    # Every outcome — including the unknown one — lands on the audit feed and in
    # the transcript, so the conversation itself records what the click did.
    BusterClaw.Sentinel.observe(:outbound_send, "Trading order submission settled", %{
      source: "trading_chat_order",
      order: summary,
      outcome: order_outcome_tag(result),
      agent: BusterClaw.ModelPolicy.backend_for(:order_submit),
      model: BusterClaw.ModelPolicy.for_surface(:order_submit) || "cli default"
    })

    socket
    |> put_chat(conv, &%{&1 | pending_order: {:settled, order, result}})
    |> push_msg_to(conv, :meta, order_transcript_line(summary, result))
  end

  defp order_outcome_tag({:ok, _id}), do: "accepted"
  defp order_outcome_tag({:error, {:refused, _reason}}), do: "refused"
  defp order_outcome_tag({:error, _reason}), do: "unknown"

  defp order_transcript_line(summary, {:ok, id}),
    do: "Order sent — #{summary}. Broker order id #{id}."

  defp order_transcript_line(summary, {:error, {:refused, reason}}),
    do: "Order refused by the broker — #{summary}. Reason: #{reason}."

  defp order_transcript_line(summary, {:error, _reason}),
    do:
      "Order status UNKNOWN — #{summary}. The submission did not return a verdict; " <>
        "check your Robinhood order history before trying again."

  defp order_error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp order_error(_reason), do: "unreadable order"

  defp move_lookup_cursor(socket, "ArrowDown"), do: nudge_cursor(socket, +1)
  defp move_lookup_cursor(socket, "ArrowUp"), do: nudge_cursor(socket, -1)

  defp move_lookup_cursor(socket, "Escape"), do: assign(socket, :lookup_cursor, nil)

  defp move_lookup_cursor(socket, "Enter") do
    matches = socket.assigns.lookup_matches

    case socket.assigns.lookup_cursor do
      i when is_integer(i) and i >= 0 ->
        case Enum.at(matches, i) do
          %{symbol: symbol} ->
            socket
            |> put_lookup(Fetch.load(symbol))
            |> assign(:lookup_query, "")
            |> assign(:lookup_matches, [])
            |> assign(:lookup_cursor, nil)

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  # Every other key: typing is handled by the form's own change event.
  defp move_lookup_cursor(socket, _key), do: socket

  # Clamped rather than wrapping. A list that jumps from the last row back to the
  # first reads as a glitch in a box this small, and there is no case here where
  # a long list makes wrapping worth it.
  defp nudge_cursor(socket, delta) do
    case socket.assigns.lookup_matches do
      [] ->
        socket

      matches ->
        last = length(matches) - 1
        current = socket.assigns.lookup_cursor

        next =
          case current do
            nil when delta > 0 -> 0
            nil -> last
            i -> (i + delta) |> max(0) |> min(last)
          end

        assign(socket, :lookup_cursor, next)
    end
  end

  # ---------------------------------------------------------------------------
  # Watchlists (left rail)
  # ---------------------------------------------------------------------------

  # Every one of these re-reads through `assign_watchlists/1` rather than
  # patching the assign in place: the depth beside each symbol comes from the
  # market cache, which a background tick can change under us.
  defp assign_watchlists(socket) do
    lists = Watchlist.all()

    depths =
      lists
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Map.new(&{&1, symbol_depth(&1)})

    socket
    |> assign(:watchlists, lists)
    |> assign(:watchlist_depths, depths)
  end

  # `:deep` / `{:short, n}` / `{:failed, on}` / nil — the three answers to "why
  # is this chart short?", plus "nothing has happened yet". Reads
  # `MarketData.backfill_status/1` so the sidebar and the recorder agree.
  defp symbol_depth(symbol) do
    case MarketData.backfill_status(symbol) do
      :deep ->
        :deep

      {:failed, on, _reason} ->
        {:failed, on}

      :never_tried ->
        case length(MarketData.bars(symbol)) do
          0 -> nil
          n -> {:short, n}
        end
    end
  end

  defp flash_watchlist(socket, {:ok, _lists}), do: assign_watchlists(socket)

  defp flash_watchlist(socket, {:error, reason}),
    do: put_flash(socket, :error, watchlist_error(reason))

  defp watchlist_error({:exists, name}), do: "A list called #{name} already exists."
  defp watchlist_error({:no_such_list, name}), do: "No list called #{name}."
  defp watchlist_error({:bad_symbol, given}), do: "#{given} does not look like a ticker."
  defp watchlist_error(:blank_name), do: "Give the list a name."
  defp watchlist_error(:name_too_long), do: "That name is too long."
  defp watchlist_error(other), do: "Could not update the watchlist (#{inspect(other)})."

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <%!-- The box the floating chat windows are allowed to move in. `relative`
            is inert while they are `fixed` (a positioned ancestor does not form a
            containing block for fixed), and becomes their whole world the moment
            this tab is joined into a split pane and they turn `absolute`. --%>
      <div id="trading-root" class="relative flex min-h-0 flex-1 flex-col">
        <section class="flex min-h-0 flex-1 flex-col gap-2 p-4">
          <.trading_tabs
            tabs={@tabs}
            active={@active_tab}
            menu_open={@new_tab_open}
            open_chats={@open_chats}
          />
          <%!-- The left rail. It wraps the tab body rather than replacing any of
                it, so the three kind-blocks below are untouched — moving the data
                panels in beside the watchlists is a restructure of all three and
                belongs in its own change. --%>
          <div class="flex min-h-0 flex-1 gap-2">
            <.watchlist_sidebar
              open={@watchlist_open}
              lists={@watchlists}
              depths={@watchlist_depths}
            >
              <%!-- The symbol lookup moved here from a right-hand column inside
                    the Chart Build panel. Its original comment argued for "beside
                    the chart", so the operator can read a looked-up figure
                    against a drawn one — the left rail is still beside it, and
                    now the tab has ONE place for ticker things: search a symbol,
                    and the lists you keep. --%>
              <:panel :if={@active_kind in ["robinhood", "chartbuild"]}>
                <%!-- Chart Build ONLY. It states the stronger fact — the broker
                      isn't restricted in that chat, it's absent, with no Robinhood
                      tool to deny. On the Robinhood tab the same sentence would be
                      false: that chat can see your accounts, which is the whole
                      point of it. The lookup below is public-data either way; the
                      banner is a claim about the CHAT, not about the search. --%>
                <div
                  :if={@active_kind == "chartbuild"}
                  id="trading-lookup-banner"
                  class="border-2 border-info/40 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-info"
                >
                  Public data only — this chat cannot see your accounts
                </div>
                <.lookup_card
                  panel={lookup_panel(assigns)}
                  query={@lookup_query}
                  matches={@lookup_matches}
                  cursor={@lookup_cursor}
                />
              </:panel>
            </.watchlist_sidebar>
            <div class="flex min-h-0 flex-1 flex-col gap-2">
              <%!-- The panel owns the whole tab. Chat is not beside it any more but on
              top of it, in windows the operator places — which is why the panel
              gets to be this wide and why those windows are translucent. --%>
              <div
                :if={@active_kind == "robinhood" and not docked?(@tabs, @active_tab)}
                class="flex min-h-0 flex-1 flex-col gap-2"
              >
                <div
                  id="trading-read-only-banner"
                  class="border-2 border-success/40 px-3 py-1.5 font-mono text-xs text-success"
                >
                  <p class="font-bold uppercase tracking-wide">
                    New orders leave only from a card you click — but this chat can cancel on its own
                  </p>
                  <p class="pt-0.5 text-[0.68rem] text-success/70">
                    Ask it to buy or sell and Buster Claw shows you the exact order to confirm.
                    Ask it to cancel a resting order and it does that directly, without a card —
                    every cancellation is recorded on the Security feed.
                  </p>
                </div>
                <%!-- First-run setup: the OAuth handshake is interactive by nature
                (a browser window), so it happens once in a terminal — the
                keychain tokens are then reused by every headless turn. --%>
                <div
                  :if={chat_state(assigns, @active_tab).seq == 0}
                  class="space-y-2 border-2 border-base-content/20 p-4 font-mono text-xs"
                >
                  <p class="font-bold uppercase tracking-wide">One-time setup (in a terminal)</p>
                  <pre class="overflow-x-auto bg-base-200 p-2">claude mcp add --transport http --scope user robinhood https://agent.robinhood.com/mcp/trading</pre>
                  <pre class="overflow-x-auto bg-base-200 p-2">claude mcp login robinhood</pre>
                  <p class="text-base-content/70">
                    The login opens Robinhood's OAuth page in your browser; tokens land in the
                    macOS Keychain and every trading turn here reuses them. Known issue
                    (claude-code #65895): if the tools still report unavailable after logging
                    in, run <code class="font-bold">claude mcp logout robinhood</code>
                    and log in again.
                  </p>
                </div>
                <.trading_account_card
                  account={@trading_account}
                  selected_id={@trading_account_sel}
                  all_accounts={@all_accounts}
                  detail={@trading_detail}
                  anomaly={@trading_anomaly}
                  series={@trading_series}
                  performance_state={@trading_performance_state}
                  range={@trading_range}
                  coverage={@trading_coverage}
                  backfilling={@trading_backfilling}
                  table={@trading_table}
                  day_change={@trading_day_change}
                  indexes_state={@market_indexes_state}
                  positions={@trading_positions}
                  positions_state={@trading_positions_state}
                  costs_missing={@trading_costs_missing}
                  costs_loading={@trading_costs_loading}
                  prices_state={@prices_state}
                  chart_view={@trading_chart_view}
                  symbol_bars={@symbol_bars}
                  symbol_range={@symbol_range}
                  symbol_mode={@symbol_mode}
                  symbol_state={@symbol_bars_state}
                  earnings={@trading_earnings}
                  earnings_state={@trading_earnings_state}
                />
              </div>

              <%!-- Chart Build owns its whole tab: the newest sanitized SVG above its
              typed conversation, with the symbol lookup beside them. Its
              persisted dock flag stays false because this is a data-panel kind,
              not a docked window.

              The lookup sits in its own column on purpose. Chart Build can
              search the web now, so the operator needs one region of this tab
              where every figure demonstrably came from our own fetch rather than
              from the model — and "beside the chart" is the only placement where
              you can read the two against each other. --%>
              <div
                :if={@active_kind == "chartbuild"}
                id="chartbuild-panel"
                class="flex min-h-0 flex-1 flex-col gap-2 lg:flex-row"
              >
                <div class="flex min-h-0 flex-1 flex-col gap-2">
                  <.chart_preview
                    charts={chat_state(assigns, @active_tab).svgs}
                    zoomed={chat_state(assigns, @active_tab).zoomed_id}
                  />
                  <BusterClawWeb.ChatPanel.chat_window
                    id={"chartbuild-chat-#{@active_tab}"}
                    conv={@active_tab}
                    embedded
                    index={0}
                    title={tab_title(@tabs, @active_tab)}
                    kind={@active_kind}
                    messages={chat_state(assigns, @active_tab).messages}
                    seq={chat_state(assigns, @active_tab).seq}
                    running={chat_state(assigns, @active_tab).running}
                    steerable={chat_state(assigns, @active_tab).steerable}
                    announcement={@chat_announcement}
                    thinking={chat_state(assigns, @active_tab).thinking}
                    queue={chat_state(assigns, @active_tab).queue}
                    minimized={MapSet.member?(@minimized, @active_tab)}
                    focused
                    agent_cli_missing={@agent_cli_missing}
                    empty_message={chat_empty_message(@active_kind)}
                    placeholder={chat_placeholder(@active_kind)}
                  />
                </div>
              </div>
              <%!-- A docked chat IS the tab's content: same component, positioned in
              flow instead of fixed. Its panel is hidden while it is docked, and
              floating it again brings the panel straight back. --%>
              <BusterClawWeb.ChatPanel.chat_window
                :if={docked?(@tabs, @active_tab)}
                id={"trading-dock-#{@active_tab}"}
                conv={@active_tab}
                docked
                index={0}
                title={tab_title(@tabs, @active_tab)}
                kind={@active_kind}
                messages={chat_state(assigns, @active_tab).messages}
                seq={chat_state(assigns, @active_tab).seq}
                running={chat_state(assigns, @active_tab).running}
                steerable={chat_state(assigns, @active_tab).steerable}
                announcement={@chat_announcement}
                thinking={chat_state(assigns, @active_tab).thinking}
                queue={chat_state(assigns, @active_tab).queue}
                focused
                agent_cli_missing={@agent_cli_missing}
                empty_message={chat_empty_message(@active_kind)}
                placeholder={chat_placeholder(@active_kind)}
              >
                <:pinned :if={chat_state(assigns, @active_tab).pending_order}>
                  <.order_confirm
                    conv={@active_tab}
                    pending={chat_state(assigns, @active_tab).pending_order}
                  />
                </:pinned>
              </BusterClawWeb.ChatPanel.chat_window>

              <%!-- A neutral chat has no data panel of its own, so an undocked one
              leaves the tab empty. Say why, and name the gesture that fills it. --%>
              <div
                :if={@active_kind == "chat" and not docked?(@tabs, @active_tab)}
                id="trading-float-hint"
                class="m-auto max-w-sm text-center font-mono text-xs text-base-content/50"
              >
                <p class="font-bold uppercase tracking-wide">This chat is floating</p>
                <p class="pt-2 leading-relaxed">
                  Drag its window back onto the tab bar to dock it here again, or point
                  it at Robinhood or Chart Build from the selector in its title bar.
                </p>
              </div>
            </div>
          </div>
        </section>

        <%!-- Rendered outside the section, and outside the tab switch: a window
            stays exactly where it is when the panel underneath it changes. Order
            is focus order — the last one drawn is the opaque, keyboard-owning
            one. --%>
        <BusterClawWeb.ChatPanel.chat_window
          :for={
            {conv, i} <-
              Enum.with_index(
                Enum.reject(
                  @open_chats,
                  &(docked?(@tabs, &1) or tab_kind_of(@tabs, &1) == "chartbuild")
                )
              )
          }
          id={"trading-chat-#{conv}"}
          conv={conv}
          in_pane={@embedded?}
          index={i}
          title={tab_title(@tabs, conv)}
          kind={tab_kind_of(@tabs, conv)}
          messages={chat_state(assigns, conv).messages}
          seq={chat_state(assigns, conv).seq}
          running={chat_state(assigns, conv).running}
          steerable={chat_state(assigns, conv).steerable}
          announcement={@chat_announcement}
          thinking={chat_state(assigns, conv).thinking}
          queue={chat_state(assigns, conv).queue}
          minimized={MapSet.member?(@minimized, conv)}
          focused={conv == List.last(@open_chats)}
          agent_cli_missing={@agent_cli_missing}
          empty_message={chat_empty_message(tab_kind_of(@tabs, conv))}
          placeholder={chat_placeholder(tab_kind_of(@tabs, conv))}
        >
          <:pinned :if={chat_state(assigns, conv).pending_order}>
            <.order_confirm conv={conv} pending={chat_state(assigns, conv).pending_order} />
          </:pinned>
        </BusterClawWeb.ChatPanel.chat_window>

        <%!-- Deliberately not pane-bound: a zoomed chart wants the whole window,
              and a modal that covers everything is what "zoom" means. --%>
        <BusterClawWeb.ChatPanel.svg_modal
          :if={@active_kind == "chartbuild"}
          svgs={active_charts(assigns)}
          zoomed={chat_state(assigns, @active_tab).zoomed_id}
        />
      </div>
    </Layouts.app>
    """
  end

  defp trading_cli_missing? do
    not match?({:ok, {:claude, _path}}, BusterClaw.AgentRunner.detect())
  end
end
