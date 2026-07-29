defmodule BusterClawWeb.TradingLive do
  @moduledoc """
  The Trading tab (TRADING_TAB_ROADMAP Phase 0): the pinned agent conversation
  beside the accounts dashboard, moved wholesale out of the Home page's sub-tab
  into a top-level routed surface.

  ## The chat

  One conversation, always `Trading.conv_id()` — DB-less on purpose (no
  `Conversations` row, so it can't appear in or be closed from Home's chat
  strip) while the transcript persists via `Agent.Transcript`. This view owns
  the whole chat surface for it: no tab strip, no autotitle, no SVG sketchpad
  (the trading agent quotes prices; it does not draw). Every send lands a
  Sentinel `:outbound_send` line — the audit posture for money-adjacent turns.

  ## The dashboard

  Stage-1 balances (all accounts), stage-2 holdings on demand, the cumulative
  gain/loss chart, the transfer prompt, exclusions, and the backfill control —
  verbatim from the Home sub-tab. Later phases replace pieces of this column
  with the hero row / positions / symbol charts; Phase 0 only relocates.
  """
  use BusterClawWeb, :live_view

  require Logger

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.DataState
  alias BusterClaw.Portfolio
  alias BusterClaw.Research
  alias BusterClaw.Trading

  # The combined-total chip. A sentinel rather than nil so the selection is
  # always an explicit choice, and so it round-trips through phx-value-id.
  @all_accounts "__all__"
  @portfolio_ranges ~w(1W 1M 3M 1Y ALL)
  @symbol_ranges ~w(1M 3M 1Y 5Y)
  @symbol_modes ~w(line candles)
  # How old a holdings read may be before an EMPTY one stops counting as a
  # confirmation. This only ever gates the wording of "no positions — all cash":
  # everything else says its age and lets the reader judge. Twelve hours, not
  # minutes — holdings are fetched by an explicit agent run, so a 15-minute
  # threshold marked every panel stale within a quarter hour of the only refresh
  # the user ever asks for, which is an alarm that is always ringing.
  @holdings_stale_min 12 * 60

  # Cap the retained in-memory transcript on a long-lived tab; the persisted
  # transcript is the source of truth and is re-read on mount.
  @max_chat_messages 200

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
      |> assign(:agent_cli_missing, trading_cli_missing?())
      |> assign(:tabs, Enum.map(tabs, &to_tab/1))
      |> assign(:active_tab, active.id)
      |> assign(:active_kind, active.kind)
      |> assign(:new_tab_open, false)
      # Research panel state per conversation, so switching tabs doesn't lose
      # the symbol a tab was looking at.
      |> assign(:research, %{})
      |> assign(:research_query, "")
      |> assign(:research_matches, [])
      # One state map per conversation. Several windows render at once, so there
      # is no single "the chat" to hold running/queue/transcript for any more.
      |> assign(:chats, Map.new(tabs, &{&1.id, initial_chat_state(&1.id)}))
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
      {true, trimmed} when trimmed != "" -> {:noreply, dispatch_chat(socket, conv, trimmed)}
      _ -> {:noreply, socket}
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
      when kind in ["chat", "robinhood", "research"] do
    # A new tab starts docked — it opens as a sub-tab rather than a window the
    # operator has to place. The exception is a kind that HAS a data panel:
    # docking a Robinhood or Research tab hides the very dashboard you just
    # asked for, so those start with the panel showing and the chat floating
    # over it. Either can be dragged or buttoned into the other state after.
    docked = kind == "chat"

    {:ok, conv} =
      Conversations.create(%{title: Trading.kind_label(kind), kind: kind, docked: docked})

    if connected?(socket), do: Chat.subscribe(conv.id)

    # A tab you just made is one you want to talk to, so a floating one opens
    # with it — and appended, so it is the focused one. Selecting an EXISTING
    # tab deliberately does not do this: a window the operator closed stays
    # closed. A docked tab needs no window; it is already the tab.
    open_chats =
      if docked, do: socket.assigns.open_chats, else: socket.assigns.open_chats ++ [conv.id]

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
  # claude session. Without that, a Robinhood chat retyped to Research would
  # `--resume` into a context full of account balances that the research toolset
  # is specifically supposed to have no way of seeing.
  def handle_event("trading_set_kind", %{"id" => id, "kind" => kind}, socket)
      when kind in ["chat", "robinhood", "research"] do
    if known_tab?(socket, id) and tab_kind(socket, id) != kind do
      {:ok, _conv} = Conversations.set_kind(id, kind)
      Chat.stop(id)

      {:noreply,
       socket
       |> update_tab(id, &%{&1 | kind: kind, running: false})
       |> put_chat(id, &%{&1 | running: false, thinking: nil, queue: [], pending_order: nil})
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

  # ---------------------------------------------------------------------------
  # Research panel
  # ---------------------------------------------------------------------------

  def handle_event("research_search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:research_query, query)
     |> assign(:research_matches, Research.search(query))}
  end

  def handle_event("research_open", %{"symbol" => symbol}, socket) do
    # Loaded synchronously: three small HTTP GETs against free endpoints, not an
    # agent run. There is no token cost to defer and no model to wait for.
    {:noreply,
     socket
     |> put_research(Research.load(symbol))
     |> assign(:research_query, "")
     |> assign(:research_matches, [])}
  end

  def handle_event("research_clear", _params, socket) do
    {:noreply,
     socket
     |> put_research(Research.blank())
     |> assign(:research_query, "")
     |> assign(:research_matches, [])}
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
        BusterClaw.Sentinel.observe(:outbound_send, "Trading order confirmed by operator", %{
          source: "trading_chat_order",
          conv_id: conv,
          order: BusterClaw.TradingOrder.summary(order)
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

    # A finished trading run may have moved money — re-snapshot the accounts
    # while the operator is looking at them.
    if status == :idle, do: maybe_refresh_account(socket), else: socket
  end

  defp apply_chat(socket, conv, {:thinking, ms}),
    do: put_chat(socket, conv, &%{&1 | thinking: {:done, ms}})

  defp apply_chat(socket, conv, {:queue, items}),
    do: put_chat(socket, conv, &%{&1 | queue: items})

  defp apply_chat(socket, conv, {:message, %{role: role, text: text}}) do
    socket
    |> maybe_speak(conv, role, text)
    |> push_msg_to(conv, role, text)
    |> maybe_propose_order(conv, role, text)
    |> maybe_flag_unread(conv, role)
  end

  defp apply_chat(socket, _conv, _other), do: socket

  # A window that is closed or collapsed cannot be read, so its tab carries the
  # dot instead. An open, expanded window is already showing the message.
  defp maybe_flag_unread(socket, _conv, :user), do: socket

  defp maybe_flag_unread(socket, conv, _role) do
    if conv in socket.assigns.open_chats and not MapSet.member?(socket.assigns.minimized, conv),
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
        put_chat(socket, conv, &%{&1 | pending_order: {:proposed, order}})

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

  defp dispatch_chat(socket, conv_id, text) do
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

        # The kind decides the toolset: a research window must never be started
        # with the broker's options just because it shares this dispatcher.
        Chat.ensure_started(conv_id, Trading.chat_opts_for(tab_kind(socket, conv_id)))
        do_send(socket, conv_id, text)

      _other ->
        push_msg_to(socket, conv_id, :error, "Trading requires the Claude Code CLI.")
    end
  catch
    :exit, _reason ->
      push_msg_to(socket, conv_id, :error, "Chat backend isn't running — restart the server.")
  end

  # While a run is in flight send_message/2 queues the text (returns :ok) rather
  # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
  defp do_send(socket, conv_id, text) do
    case Chat.send_message(conv_id, text) do
      :ok ->
        socket

      {:error, :no_agent_cli} ->
        socket

      {:error, reason} ->
        push_msg_to(socket, conv_id, :error, "Could not start the run: #{inspect(reason)}")
    end
  end

  # Panel-side errors (a failed cost fetch, a crashed bar run) belong to whichever
  # conversation the operator is looking at, which is the active tab's.
  defp push_msg(socket, role, text),
    do: push_msg_to(socket, socket.assigns.active_tab, role, text)

  defp push_msg_to(socket, conv, role, text) do
    put_chat(socket, conv, fn c ->
      seq = c.seq + 1
      msg = %{id: seq, role: role, text: text, svg_ids: []}

      %{
        c
        | seq: seq,
          messages:
            Enum.take(c.messages ++ [{"chat-msg-#{conv}-#{seq}", msg}], -@max_chat_messages)
      }
    end)
  end

  # --- Per-conversation chat state ---

  defp initial_chat_state(conv_id) do
    messages = load_history(conv_id)

    %{
      messages: messages,
      seq: length(messages),
      running: Chat.running?(conv_id),
      thinking: if(Chat.running?(conv_id), do: :running, else: nil),
      queue: Chat.queue(conv_id),
      pending_order: nil
    }
  end

  defp chat_state(assigns_or_socket, conv) do
    Map.get(assigns_or_socket.chats, conv) || empty_chat_state()
  end

  defp empty_chat_state,
    do: %{messages: [], seq: 0, running: false, thinking: nil, queue: [], pending_order: nil}

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

  # Restore the transcript from the conversation's persisted history. Unlike the
  # Home chat there is no SVG extraction: the trading agent quotes numbers, and
  # a sketchpad here would be a second surface to keep honest for no benefit.
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

    socket
    |> assign(:active_tab, id)
    |> update(:chats, fn chats ->
      Map.put_new_lazy(chats, id, fn -> initial_chat_state(id) end)
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
      |> update(:research, &Map.delete(&1, id))
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

  # --- Research helpers ---

  defp put_research(socket, panel),
    do: update(socket, :research, &Map.put(&1, socket.assigns.active_tab, panel))

  defp research_panel(socket_or_assigns) do
    Map.get(socket_or_assigns.research, socket_or_assigns.active_tab) || Research.blank()
  end

  defp load_history(conv_id) do
    conv_id
    |> AgentTranscript.recent(limit: 200)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, i} ->
      {"chat-msg-#{conv_id}-#{i}",
       %{id: i, role: history_role(row.role), text: row.content, svg_ids: []}}
    end)
  end

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

  defp state_data(%DataState{data: data}) when is_list(data), do: data
  defp state_data(%DataState{}), do: []

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

  # Range -> (window, interval). 5Y is weekly because ~260 rows is the most
  # transcription one run may carry; the disclosure line says which is showing.
  defp symbol_window("1M"), do: {31, "day"}
  defp symbol_window("3M"), do: {93, "day"}
  defp symbol_window("1Y"), do: {366, "day"}
  defp symbol_window("5Y"), do: {1830, "week"}

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

  defp last_snapshot({:ok, snap}), do: snap
  defp last_snapshot({:loading, prev}), do: prev
  defp last_snapshot({:error, _reason, prev}), do: prev
  defp last_snapshot(_), do: nil

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

  attr :panel, :map, required: true
  attr :query, :string, required: true
  attr :matches, :list, required: true

  # Everything here is rendered from what the APP fetched — Finnhub and EDGAR
  # through `BusterClaw.Finance` — never from anything the model typed. Each
  # dataset states its own source and age because each can fail alone.
  defp research_card(assigns) do
    ~H"""
    <aside
      id="trading-research-card"
      class="ic-panel flex min-h-0 w-full flex-col overflow-y-auto p-4 font-mono text-xs"
    >
      <form phx-change="research_search" phx-submit="research_search" autocomplete="off">
        <input
          type="text"
          name="query"
          value={@query}
          placeholder="Search a ticker or company…"
          class="w-full border-2 border-base-content/25 bg-base-100 px-2 py-1.5 focus:border-primary focus:outline-none"
        />
      </form>

      <div
        :if={@matches != []}
        class="mt-1 divide-y divide-base-content/10 border-2 border-base-content/20"
      >
        <button
          :for={match <- @matches}
          type="button"
          phx-click="research_open"
          phx-value-symbol={match.symbol}
          class="flex w-full items-baseline gap-2 px-2 py-1.5 text-left transition hover:bg-base-content/10"
        >
          <span class="font-bold">{match.symbol}</span>
          <span class="truncate text-base-content/60">{match.name}</span>
        </button>
      </div>

      <p :if={is_nil(@panel.symbol)} class="pt-6 text-center text-base-content/50">
        Search a ticker above to see its quote, fundamentals and recent SEC filings.
      </p>

      <div :if={@panel.symbol} class="pt-3">
        <div class="flex items-baseline justify-between border-b border-base-content/15 pb-1">
          <p class="text-lg font-black tracking-wide">{@panel.symbol}</p>
          <button
            type="button"
            phx-click="research_clear"
            class="uppercase tracking-wide text-base-content/50 hover:text-base-content"
          >
            Clear
          </button>
        </div>

        <%!-- Quote. The delay is stated every time: a free-tier print is not a
              live one, and a number without its age invites being read as now. --%>
        <div class="pt-3">
          <div :if={@panel.quote.status == :fresh} class="flex items-baseline gap-3">
            <p class="text-2xl font-black">{research_price(@panel.quote.data)}</p>
            <p class={research_change_class(@panel.quote.data)}>
              {research_change(@panel.quote.data)}
            </p>
          </div>
          <p :if={@panel.quote.status == :fresh} class="pt-0.5 text-base-content/40">
            {@panel.quote.data.source} · delayed ~15 min · {as_of_label(@panel.quote)}
          </p>
          <p :if={@panel.quote.reason == :not_configured} class="text-base-content/50">
            No quote — set FINNHUB_API_KEY to enable prices. Filings below are unaffected.
          </p>
          <p
            :if={@panel.quote.status == :unavailable and @panel.quote.reason != :not_configured}
            class="text-base-content/50"
          >
            Quote unavailable for {@panel.symbol}.
          </p>
        </div>

        <div class="pt-4">
          <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
            Fundamentals
          </p>
          <p :if={@panel.fundamentals.status != :fresh} class="pt-2 text-base-content/50">
            {research_edgar_error(@panel.fundamentals, @panel.symbol)}
          </p>
          <div :if={@panel.fundamentals.status == :fresh} class="pt-2">
            <p
              :for={{label, value} <- research_facts(@panel.fundamentals.data)}
              class="flex justify-between gap-3 py-0.5"
            >
              <span class="text-base-content/60">{label}</span>
              <span class="font-bold">{value}</span>
            </p>
            <p class="pt-1 text-base-content/40">
              SEC EDGAR (XBRL) · {as_of_label(@panel.fundamentals)}
            </p>
          </div>
        </div>

        <div class="pt-4">
          <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
            Recent filings
          </p>
          <p :if={@panel.filings.status != :fresh} class="pt-2 text-base-content/50">
            {research_edgar_error(@panel.filings, @panel.symbol)}
          </p>
          <div :if={@panel.filings.status == :fresh} class="divide-y divide-base-content/10 pt-1">
            <p
              :for={filing <- research_filings(@panel.filings.data)}
              class="flex justify-between gap-3 py-1"
            >
              <span class="font-bold">{filing.form}</span>
              <span class="text-base-content/60">{filing.filed_on}</span>
            </p>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  # --- Research renderers ---
  #
  # Every one of these tolerates a nil: EDGAR returns a fact map whose values are
  # individually nil when a company never filed that concept, and Finnhub returns
  # zeros for a symbol it does not cover. A dash is the honest render for both —
  # never a 0, which would read as a real measurement of nothing.

  defp research_price(%{price: price}) when is_number(price) and price > 0,
    do: "$" <> :erlang.float_to_binary(price * 1.0, decimals: 2)

  defp research_price(_quote), do: "—"

  defp research_change(%{percent_change: pct, change: change})
       when is_number(pct) and is_number(change) do
    "#{signed_pct(pct)} (#{signed_money(round(change * 100))})"
  end

  defp research_change(_quote), do: "—"

  defp research_change_class(%{percent_change: pct}) when is_number(pct) and pct > 0,
    do: "font-bold text-success"

  defp research_change_class(%{percent_change: pct}) when is_number(pct) and pct < 0,
    do: "font-bold text-error"

  defp research_change_class(_quote), do: "text-base-content/60"

  @fundamental_labels [
    revenue: "Revenue",
    net_income: "Net income",
    assets: "Assets",
    liabilities: "Liabilities",
    stockholders_equity: "Shareholders' equity"
  ]

  defp research_facts(%{facts: facts}) when is_map(facts) do
    Enum.map(@fundamental_labels, fn {key, label} ->
      {label, research_fact_value(Map.get(facts, key))}
    end)
  end

  defp research_facts(_data), do: []

  # The period is part of the figure. A revenue number with no year attached is
  # a number the reader has to guess the meaning of.
  defp research_fact_value(%{value: value, as_of: as_of}) when is_number(value) do
    "#{research_big_money(value)}#{if as_of, do: " (#{as_of})", else: ""}"
  end

  defp research_fact_value(_fact), do: "—"

  defp research_big_money(value) when is_number(value) do
    abs = abs(value)

    cond do
      abs >= 1_000_000_000 -> "$#{Float.round(value / 1_000_000_000, 2)}B"
      abs >= 1_000_000 -> "$#{Float.round(value / 1_000_000, 1)}M"
      true -> "$#{round(value)}"
    end
  end

  defp research_filings(%{filings: filings}) when is_list(filings) do
    filings
    |> Enum.take(8)
    |> Enum.map(&%{form: &1.form || "—", filed_on: &1.filing_date || "—"})
  end

  defp research_filings(_data), do: []

  defp research_edgar_error(%DataState{reason: {:unknown_symbol, _sym}}, symbol),
    do: "SEC EDGAR has no company matching #{symbol}."

  defp research_edgar_error(%DataState{reason: :no_symbol}, _symbol),
    do: "Search a ticker to load this."

  defp research_edgar_error(_state, _symbol),
    do: "SEC EDGAR could not be reached."

  attr :tabs, :list, required: true
  attr :active, :string, required: true
  attr :menu_open, :boolean, required: true
  attr :open_chats, :list, required: true

  defp trading_tabs(assigns) do
    ~H"""
    <%!-- The strip doubles as the dock target: drag a floating chat onto it and
          it becomes a sub-tab. `bc-dropzone-active` is toggled by the ChatWindow
          hook while a window is over it. --%>
    <div
      id="trading-tab-strip"
      data-tab-dropzone
      class="relative flex items-center gap-1 rounded-sm border-2 border-transparent px-1 py-0.5 transition"
      role="tablist"
      aria-label="Trading tabs"
    >
      <div
        :for={tab <- @tabs}
        id={"trading-tab-#{tab.id}"}
        role="tab"
        aria-selected={to_string(tab.id == @active)}
        phx-click="trading_select_tab"
        phx-value-id={tab.id}
        class={[
          "group flex shrink-0 cursor-pointer items-center gap-1.5 rounded-t-sm border-2 px-2.5 py-1.5 font-mono text-xs transition",
          if(tab.id == @active,
            do: "border-base-content/30 bg-base-200 text-base-content",
            else: "border-base-content/15 bg-base-200/40 text-base-content/55 hover:text-base-content"
          )
        ]}
      >
        <%!-- The kind is written, not merely coloured: which surface a tab can
              reach is the single most important thing about it. --%>
        <span class={[
          "shrink-0 border px-1 text-[0.55rem] font-black uppercase tracking-wider",
          if(tab.kind == "research",
            do: "border-info/50 text-info",
            else: "border-success/50 text-success"
          )
        ]}>
          {Trading.kind_badge(tab.kind)}
        </span>
        <span
          :if={tab.docked}
          title="This chat is docked into the tab"
          class="shrink-0 font-mono text-[0.6rem] text-base-content/40"
        >
          ⊞
        </span>
        <span
          :if={tab.running}
          class="size-2 shrink-0 animate-pulse rounded-full bg-primary"
          title="Working"
        >
        </span>
        <span
          :if={tab.unread and tab.id != @active}
          class="size-2 shrink-0 rounded-full bg-warning"
          title="New messages"
        >
        </span>
        <span class="max-w-[10rem] truncate font-medium">{tab.title}</span>
        <%!-- Opening a chat is separate from selecting a tab, because the two are
              now separate things: the tab decides the panel, the window decides
              which conversation you are talking to. --%>
        <span
          phx-click="trading_toggle_chat"
          phx-value-id={tab.id}
          title={if tab.id in @open_chats, do: "Close this chat window", else: "Open this chat"}
          class={[
            "grid size-4 shrink-0 place-items-center rounded-sm transition hover:bg-base-content/15",
            if(tab.id in @open_chats,
              do: "text-primary",
              else: "text-base-content/40 hover:text-base-content"
            )
          ]}
        >
          <.icon name="hero-chat-bubble-left" class="size-3.5" />
        </span>
        <span
          phx-click="trading_close_tab"
          phx-value-id={tab.id}
          title="Close tab"
          class="ml-0.5 grid size-4 shrink-0 place-items-center rounded-sm text-base-content/40 hover:bg-base-content/15 hover:text-primary"
        >
          ×
        </span>
      </div>

      <button
        id="trading-new-tab"
        type="button"
        phx-click="trading_new_tab_menu"
        title="New tab"
        aria-label="New tab"
        aria-expanded={to_string(@menu_open)}
        class="grid size-7 shrink-0 place-items-center rounded-sm border-2 border-base-content/20 font-mono text-base-content/70 transition hover:border-primary hover:text-primary"
      >
        +
      </button>

      <div
        :if={@menu_open}
        id="trading-new-tab-menu"
        class="absolute left-0 top-full z-20 mt-1 w-56 border-2 border-base-content/25 bg-base-100 font-mono text-xs shadow-[3px_3px_0_0_oklch(var(--bc)/0.15)]"
      >
        <%!-- Chat leads: it is the neutral one, and it can be pointed at either
              of the others afterwards. --%>
        <button
          type="button"
          phx-click="trading_new_tab"
          phx-value-kind="chat"
          class="block w-full px-3 py-2 text-left transition hover:bg-base-content/10"
        >
          <span class="font-black uppercase tracking-wide">Chat</span>
          <span class="block text-[0.68rem] text-base-content/60">
            Opens as a sub-tab · float it from its title bar
          </span>
        </button>
        <button
          type="button"
          phx-click="trading_new_tab"
          phx-value-kind="robinhood"
          class="block w-full border-t-2 border-base-content/15 px-3 py-2 text-left transition hover:bg-base-content/10"
        >
          <span class="font-black uppercase tracking-wide text-success">Robinhood</span>
          <span class="block text-[0.68rem] text-base-content/60">
            Your accounts, positions and orders
          </span>
        </button>
        <button
          type="button"
          phx-click="trading_new_tab"
          phx-value-kind="research"
          class="block w-full border-t-2 border-base-content/15 px-3 py-2 text-left transition hover:bg-base-content/10"
        >
          <span class="font-black uppercase tracking-wide text-info">Research</span>
          <span class="block text-[0.68rem] text-base-content/60">
            Public quotes and filings — no account access
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp chat_empty_message("research"),
    do:
      "Public-market research. Look up a symbol on the right, then ask about the filings, " <>
        "the fundamentals, or what the numbers mean. This chat cannot see your accounts."

  defp chat_empty_message(_robinhood),
    do:
      "Portfolio assistant. Ask about balances, positions, order history, or market data — " <>
        "or ask it to buy or sell, and it will put the order up for your confirmation."

  defp chat_placeholder("research"),
    do: "Ask about a company…  (Enter to send, Shift+Enter for a new line)"

  defp chat_placeholder(_robinhood),
    do: "Ask about your portfolio…  (Enter to send, Shift+Enter for a new line)"

  # The confirm card: the app's rendering of what it parsed, and the button that
  # sends it. Everything shown here comes from the `TradingOrder` struct, not from
  # the model's prose — so what the operator reads is exactly what gets placed.
  attr :pending, :any, required: true
  attr :conv, :string, required: true

  defp order_confirm(assigns) do
    ~H"""
    <div id={"trading-order-confirm-#{@conv}"} class="space-y-2 p-4 font-mono text-xs">
      <%= case @pending do %>
        <% {:proposed, order} -> %>
          <p class="text-[0.62rem] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Confirm to send
          </p>
          <p id={"trading-order-summary-#{@conv}"} class="text-sm font-black tracking-wide">
            {BusterClaw.TradingOrder.summary(order)}
          </p>
          <p class="text-base-content/60">
            This is what Buster Claw will send. Nothing has reached the broker yet.
          </p>
          <div class="flex gap-2 pt-1">
            <button
              id={"trading-order-confirm-button-#{@conv}"}
              type="button"
              phx-click="trading_order_confirm"
              phx-value-conv={@conv}
              class="border-2 border-error bg-error/10 px-3 py-2 font-black uppercase tracking-wide text-error transition hover:bg-error hover:text-error-content"
            >
              Place this order
            </button>
            <button
              type="button"
              phx-click="trading_order_dismiss"
              phx-value-conv={@conv}
              phx-value-conv={@conv}
              class="border-2 border-base-content/25 px-3 py-2 font-bold uppercase tracking-wide transition hover:border-base-content/50"
            >
              Discard
            </button>
          </div>
        <% {:submitting, order} -> %>
          <p class="text-[0.62rem] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Sending
          </p>
          <p class="text-sm font-black tracking-wide">
            {BusterClaw.TradingOrder.summary(order)}
          </p>
          <p id={"trading-order-submitting-#{@conv}"} class="text-base-content/60">
            Placing the order… don't close this tab.
          </p>
        <% {:settled, order, result} -> %>
          <p class={[
            "text-[0.62rem] font-bold uppercase tracking-[0.2em]",
            order_result_class(result)
          ]}>
            {order_result_heading(result)}
          </p>
          <p class="text-sm font-black tracking-wide">
            {BusterClaw.TradingOrder.summary(order)}
          </p>
          <%!-- No retry button, on purpose. A submission that did not return a
                verdict may already be live at the broker; the only safe next
                step is for a human to go look. --%>
          <p id={"trading-order-result-#{@conv}"} class={["text-xs", order_result_class(result)]}>
            {order_result_detail(result)}
          </p>
          <button
            type="button"
            phx-click="trading_order_dismiss"
            class="border-2 border-base-content/25 px-3 py-1.5 font-bold uppercase tracking-wide transition hover:border-base-content/50"
          >
            Dismiss
          </button>
      <% end %>
    </div>
    """
  end

  defp order_result_heading({:ok, _id}), do: "Sent"
  defp order_result_heading({:error, {:refused, _reason}}), do: "Refused by the broker"
  defp order_result_heading({:error, :not_sent}), do: "Not sent"
  defp order_result_heading({:error, _reason}), do: "Status unknown"

  defp order_result_class({:ok, _id}), do: "text-success"
  defp order_result_class({:error, {:refused, _reason}}), do: "text-warning"
  defp order_result_class({:error, :not_sent}), do: "text-warning"
  defp order_result_class({:error, _reason}), do: "text-error"

  defp order_result_detail({:ok, id}), do: "Broker order id #{id}."
  defp order_result_detail({:error, {:refused, reason}}), do: reason

  # `:not_sent` is a verified negative — the run made no place call at all — so
  # unlike the unknown below it is safe to say plainly that nothing happened.
  defp order_result_detail({:error, :not_sent}),
    do:
      "The order never reached Robinhood — the broker tools were not available to " <>
        "the run. Nothing was placed. Check `claude mcp login robinhood` and try again."

  defp order_result_detail({:error, _reason}),
    do:
      "The submission did not come back with a verdict, so this order may or may not " <>
        "have reached Robinhood. Check your order history there before sending it again."

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
      outcome: order_outcome_tag(result)
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

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <section class="flex min-h-0 flex-1 flex-col gap-2 p-4">
        <.trading_tabs
          tabs={@tabs}
          active={@active_tab}
          menu_open={@new_tab_open}
          open_chats={@open_chats}
        />
        <%!-- The panel owns the whole tab. Chat is not beside it any more but on
              top of it, in windows the operator places — which is why the panel
              gets to be this wide and why those windows are translucent. --%>
        <div
          :if={@active_kind == "robinhood" and not docked?(@tabs, @active_tab)}
          class="flex min-h-0 flex-1 flex-col gap-2"
        >
          <div
            id="trading-read-only-banner"
            class="border-2 border-success/40 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-success"
          >
            Read-only mode — Buster Claw cannot place, amend, or cancel Robinhood orders
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
              in, run <code class="font-bold">claude mcp logout robinhood</code> and log in again.
            </p>
          </div>
          <.trading_account_card
            account={@trading_account}
            selected_id={@trading_account_sel}
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

        <div
          :if={@active_kind == "research" and not docked?(@tabs, @active_tab)}
          class="flex min-h-0 flex-1 flex-col gap-2"
        >
          <%!-- Research states the stronger fact: the broker isn't restricted
                here, it's absent. This chat has no Robinhood tool to deny. --%>
          <div
            id="trading-research-banner"
            class="border-2 border-info/40 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-info"
          >
            Public data only — this chat cannot see your accounts
          </div>
          <.research_card
            panel={research_panel(assigns)}
            query={@research_query}
            matches={@research_matches}
          />
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
            it at Robinhood or Research from the selector in its title bar.
          </p>
        </div>
      </section>

      <%!-- Rendered outside the section, and outside the tab switch: a window
            stays exactly where it is when the panel underneath it changes. Order
            is focus order — the last one drawn is the opaque, keyboard-owning
            one. --%>
      <BusterClawWeb.ChatPanel.chat_window
        :for={{conv, i} <- Enum.with_index(Enum.reject(@open_chats, &docked?(@tabs, &1)))}
        id={"trading-chat-#{conv}"}
        conv={conv}
        index={i}
        title={tab_title(@tabs, conv)}
        kind={tab_kind_of(@tabs, conv)}
        messages={chat_state(assigns, conv).messages}
        seq={chat_state(assigns, conv).seq}
        running={chat_state(assigns, conv).running}
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
    </Layouts.app>
    """
  end

  # The accounts panel (right column). Shows whichever snapshot we have —
  # including a stale one under a spinner or error line — with an honest as-of
  # stamp; the truth costs an agent run, so it is never silently auto-polled.
  #
  # Every account is readable here. Robinhood still identifies the account that
  # is Agentic-capable, but this app disables writes at the Claude tool boundary;
  # the chip says both facts so capability is never mistaken for authorization.
  attr :account, :any, required: true
  attr :selected_id, :string, required: true
  attr :detail, :any, required: true
  attr :anomaly, :any, required: true
  attr :series, :list, required: true
  attr :performance_state, :any, required: true
  attr :range, :string, required: true
  attr :coverage, :any, required: true
  attr :backfilling, :boolean, required: true
  attr :table, :boolean, required: true
  attr :day_change, :any, required: true
  attr :indexes_state, :any, required: true
  attr :positions, :list, required: true
  attr :positions_state, :any, required: true
  attr :costs_missing, :list, required: true
  attr :costs_loading, :boolean, required: true
  attr :prices_state, :any, required: true
  attr :chart_view, :any, required: true
  attr :symbol_bars, :list, required: true
  attr :symbol_range, :string, required: true
  attr :symbol_mode, :atom, required: true
  attr :symbol_state, :any, required: true
  attr :earnings, :list, required: true
  attr :earnings_state, :any, required: true

  defp trading_account_card(assigns) do
    snap = last_snapshot(assigns.account)
    all? = assigns.selected_id == @all_accounts
    selected = if all?, do: nil, else: snap && Trading.select_account(snap, assigns.selected_id)

    assigns =
      assigns
      |> assign(:snap, snap)
      |> assign(:accounts, Trading.accounts(snap))
      |> assign(:selected, selected)
      |> assign(:all?, all?)
      |> assign(:all_accounts, @all_accounts)
      |> assign(:excluded, (assigns.coverage && assigns.coverage[:excluded]) || [])
      |> assign(:account_state, account_dataset_state(assigns.account))
      |> assign(:detail_state, detail_state(selected, assigns.detail))

    assigns =
      assign(
        assigns,
        :detail_dataset_state,
        detail_dataset_state(assigns.selected, assigns.detail_state)
      )

    assigns =
      assign(
        assigns,
        :activity,
        activity_rows(assigns.accounts, assigns.excluded, selected, assigns.detail_state)
      )

    assigns =
      assign(
        assigns,
        :transfer_activity,
        transfer_activity(assigns.accounts, assigns.excluded, selected)
      )

    ~H"""
    <aside
      id="trading-account-card"
      class="ic-panel flex min-h-0 w-full flex-col overflow-y-auto p-4 font-mono text-xs"
    >
      <%!-- The hero row (Phase 2): the five-second test. Total value and its
            day change first, market context beside them. The change comes from
            the LEDGER's two most recent readings with flows netted — the same
            series the chart draws, so the two cannot disagree — and its label
            is honest about the baseline: "today" only when no trading day
            between the readings went unrecorded. --%>
      <div class="border-b-2 border-base-content/20 pb-2">
        <div class="flex flex-wrap items-start justify-between gap-x-4 gap-y-1">
          <div>
            <p class="uppercase tracking-widest text-base-content/60">
              {cond do
                @excluded != [] -> "Included accounts"
                length(@accounts) > 1 -> "All accounts"
                true -> "Account"
              end}
            </p>
            <p :if={@snap} class="ic-stat-n text-3xl">
              {money(included_total(@snap, @excluded))}
            </p>
            <p :if={is_map(@day_change)} class="pt-0.5">
              <span class={[
                "font-bold",
                if(@day_change.change_cents < 0, do: "text-error", else: "text-success")
              ]}>
                {signed_money(@day_change.change_cents)}{pct_suffix(@day_change.change_pct)}
              </span>
              <span class="text-base-content/50">
                {if @day_change.contiguous?,
                  do: "today",
                  else: "since #{Date.to_iso8601(@day_change.prev_day)}"}
              </span>
            </p>
            <p :if={match?({:single, _}, @day_change)} class="pt-0.5 text-base-content/50">
              First reading {@day_change |> elem(1) |> Map.fetch!(:day) |> Date.to_iso8601()} —
              day change starts with tomorrow's.
            </p>
          </div>

          <%!-- "Was that me or the market": index chips from the daily sweep,
                with an as-of because cached context must say its age. A chip
                with no derivable change writes a dash, never a zero. --%>
          <div :if={state_data(@indexes_state) != []} id="trading-index-state" class="text-right">
            <div :for={chip <- state_data(@indexes_state)} class="flex justify-end gap-2">
              <span class="font-bold text-base-content/70">{chip.label}</span>
              <span class="text-base-content/80">{index_price(chip.price)}</span>
              <span class={index_change_class(chip.change_pct)}>
                {index_change(chip.change_pct)}
              </span>
            </div>
            <p class="pt-0.5 text-base-content/40">{as_of_label(@indexes_state)}</p>
          </div>
        </div>
      </div>

      <%!-- Account chips. Tabs semantically: one panel below, one selected chip.
            "All" leads because the combined total is the default question. --%>
      <div :if={@accounts != []} class="flex flex-wrap gap-1 pt-2" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={@selected_id == @all_accounts}
          phx-click="trading_select_account"
          phx-value-id={@all_accounts}
          class={[
            "flex flex-col items-start border-2 px-2 py-1 text-left transition",
            if(@selected_id == @all_accounts,
              do: "border-primary bg-primary/10",
              else: "border-base-content/25 hover:bg-base-content/5"
            )
          ]}
        >
          <span class="font-bold uppercase tracking-wide">All</span>
          <span class="text-base-content/70">{money(Trading.total_value(@snap))}</span>
        </button>
        <button
          :for={acct <- @accounts}
          type="button"
          role="tab"
          aria-selected={@selected && acct["id"] == @selected["id"]}
          phx-click="trading_select_account"
          phx-value-id={acct["id"]}
          title={"#{acct["label"]} #{acct["id"]} — #{money(acct["value"])}"}
          class={[
            "flex flex-col items-start border-2 px-2 py-1 text-left transition",
            if(@selected && acct["id"] == @selected["id"],
              do: "border-primary bg-primary/10",
              else: "border-base-content/25 hover:bg-base-content/5"
            )
          ]}
        >
          <span class="font-bold uppercase tracking-wide">{acct["label"]}</span>
          <span class="text-base-content/70">{money(acct["value"])}</span>
        </button>
      </div>

      <%!-- The transfer prompt. It ASKS; it never decides. There is no
            transfers tool on the Robinhood surface, so a large move is
            equally explainable by a deposit or by the market, and inferring
            which would mean the app making up claims about the user's money.
            Answering it — either way — is what makes it go away. --%>
      <div :if={@anomaly} class="space-y-2 border-2 border-warning/50 p-2" id="trading-anomaly-prompt">
        <p class="font-bold uppercase tracking-wide text-warning">
          {signed_money(@anomaly.gain_cents)} on {@anomaly.day}
        </p>
        <p class="text-base-content/70">
          Was that a transfer? Until it's marked, it counts as gain.
        </p>
        <form phx-submit="trading_mark_flow" class="flex flex-wrap items-center gap-1">
          <input type="hidden" name="day" value={Date.to_iso8601(@anomaly.day)} />
          <input type="hidden" name="account_key" value={@anomaly.account_key} />
          <input
            type="text"
            name="amount"
            value={abs(@anomaly.gain_cents) / 100}
            inputmode="decimal"
            aria-label="Transfer amount in dollars"
            class="w-24 border-2 border-base-content/30 bg-transparent px-1 py-0.5"
          />
          <button
            type="submit"
            name="kind"
            value={if @anomaly.gain_cents >= 0, do: "deposit", else: "withdrawal"}
            class="border-2 border-base-content/40 px-2 py-0.5 font-bold uppercase hover:bg-base-content/10"
          >
            {if @anomaly.gain_cents >= 0, do: "Deposit", else: "Withdrawal"}
          </button>
          <button
            type="submit"
            name="kind"
            value="not_a_transfer"
            class="border-2 border-base-content/25 px-2 py-0.5 uppercase text-base-content/70 hover:bg-base-content/10"
          >
            No, the market
          </button>
        </form>
      </div>

      <div :if={@chart_view == :portfolio} class="pt-3">
        <p id="trading-performance-state" class="pb-1 text-right text-base-content/40">
          {as_of_label(@performance_state)}
        </p>
        <BusterClawWeb.PortfolioChart.portfolio_chart
          series={@series}
          range={@range}
          label={
            if @all?, do: "all accounts", else: (@selected && @selected["label"]) || "this account"
          }
          coverage={@coverage}
          backfilling={@backfilling}
          table={@table}
        />
      </div>

      <%!-- One symbol's price chart (Phase 4). "Portfolio" is always one click
            away, and the disclosure line names the interval actually drawn —
            weekly at 5Y, because bounded transcription beats fake density. --%>
      <div :if={match?({:symbol, _}, @chart_view)} class="space-y-2 pt-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="trading_view_portfolio"
              class="border-2 border-base-content/30 px-2 py-0.5 uppercase tracking-wide transition hover:bg-base-content/10"
            >
              ◀ Portfolio
            </button>
            <span class="font-bold uppercase tracking-widest">{elem(@chart_view, 1)}</span>
          </div>
          <div class="flex gap-0.5 border-2 border-base-content/20 p-0.5">
            <button
              :for={{mode, label} <- [{"line", "Line"}, {"candles", "Candles"}]}
              type="button"
              phx-click="trading_symbol_mode"
              phx-value-mode={mode}
              aria-pressed={to_string(@symbol_mode) == mode}
              class={[
                "px-2 py-0.5 uppercase tracking-wide transition",
                if(to_string(@symbol_mode) == mode,
                  do: "bg-primary text-primary-content",
                  else: "text-base-content/60 hover:bg-base-content/10"
                )
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex gap-1" role="tablist" aria-label="Symbol time range">
            <button
              :for={range <- ["1M", "3M", "1Y", "5Y"]}
              type="button"
              role="tab"
              aria-selected={@symbol_range == range}
              phx-click="trading_symbol_range"
              phx-value-range={range}
              class={[
                "border-2 px-2 py-0.5 font-bold uppercase tracking-wide transition",
                if(@symbol_range == range,
                  do: "border-primary bg-primary/10",
                  else: "border-base-content/25 hover:bg-base-content/5"
                )
              ]}
            >
              {range}
            </button>
          </div>
          <span id="trading-symbol-state" class="text-right text-base-content/50">
            {if elem(symbol_window(@symbol_range), 1) == "week", do: "weekly", else: "daily"} · {length(
              @symbol_bars
            )} bars{if @symbol_state.status == :loading,
              do: " · fetching full bars (one agent run)…"}
          </span>
        </div>

        <BusterClawWeb.PortfolioChart.symbol_plot
          bars={@symbol_bars}
          mode={@symbol_mode}
          symbol={elem(@chart_view, 1)}
        />
      </div>

      <%!-- Positions across included accounts (Phase 3): what you hold, what
            it's worth, and what you PAID — which is what makes the gain a fact.
            Everything here renders from the local cache; the only agent runs
            this panel can cause are the explicit Load / Refresh buttons. --%>
      <div :if={@all?} class="pt-3">
        <div class="flex items-center justify-between border-b border-base-content/15 pb-1">
          <p class="uppercase tracking-wide text-base-content/60">Positions</p>
          <div class="flex items-center gap-2">
            <%!-- One age, not two. The prices are the number that moves, so
                  theirs is the one worth stating; cost-basis age is what the
                  Load/Refresh button and the missing-accounts line are for. --%>
            <span id="trading-positions-state" class="text-right text-base-content/40">
              {as_of_label(@prices_state)}
            </span>
            <button
              :if={@positions != [] or @costs_missing != []}
              type="button"
              phx-click="trading_load_costs"
              disabled={@costs_loading}
              class="border-2 border-base-content/30 px-2 py-0.5 uppercase tracking-wide transition hover:bg-base-content/10 disabled:opacity-50"
            >
              {cond do
                @costs_loading -> "Loading…"
                @positions == [] -> "Load"
                true -> "Refresh"
              end}
            </button>
          </div>
        </div>

        <%!-- The four empty cases stay four distinct sentences — that
              distinction is the reason DataState exists. They are just
              sentences now, not status readouts with the model's vocabulary
              in them. --%>
        <p
          :if={@positions_state.status == :loading and @positions == []}
          class="pt-2 text-base-content/50"
        >
          Loading holdings and cost basis…
        </p>
        <p
          :if={@positions_state.status == :unavailable and @costs_missing != []}
          class="pt-2 text-base-content/50"
        >
          Cost basis not loaded for {length(@costs_missing)} account{if length(@costs_missing) == 1,
            do: "",
            else: "s"} — Load fetches the
          tax lots (one agent run per account) so gains show what you actually paid.
        </p>
        <p
          :if={@positions_state.status == :unavailable and @costs_missing == []}
          class="pt-2 text-base-content/50"
        >
          No positions loaded yet — they appear once an account snapshot exists.
        </p>
        <p :if={@positions_state.status == :confirmed_empty} class="pt-2 text-base-content/50">
          No open positions{as_of_suffix(@positions_state)} — every included account is cash.
        </p>
        <p
          :if={@positions_state.status == :stale and @positions == []}
          class="pt-2 text-base-content/50"
        >
          Last read{as_of_suffix(@positions_state)} showed no positions — old enough to refresh
          before calling it all cash.
        </p>

        <div :if={@positions != []} class="divide-y divide-base-content/10">
          <div
            :for={pos <- @positions}
            class="grid grid-cols-[3.5rem_minmax(0,1fr)_5rem_5.5rem_6.5rem] items-center gap-2 py-1.5"
            title={"#{pos.symbol}: #{qty(pos.quantity)} across #{Enum.join(pos.accounts, ", ")}"}
          >
            <button
              type="button"
              phx-click="trading_view_symbol"
              phx-value-symbol={pos.symbol}
              class="min-w-0 text-left hover:bg-base-content/5"
              title={"Open the #{pos.symbol} chart"}
            >
              <p class="truncate font-bold underline decoration-base-content/30 underline-offset-2">
                {pos.symbol}
              </p>
              <p class="truncate text-base-content/50">{qty(pos.quantity)} sh</p>
            </button>
            <div class="flex justify-center">
              <BusterClawWeb.PortfolioChart.sparkline closes={pos.closes} label={pos.symbol} />
            </div>
            <div class="text-right">
              <p class="text-base-content/80">{money_cents(pos.price_cents)}</p>
              <p class={position_day_class(pos.day_change_pct)}>
                {if pos.day_change_pct, do: signed_pct(pos.day_change_pct), else: "—"}
              </p>
            </div>
            <p class="text-right text-base-content/80">{money_cents(pos.value_cents)}</p>
            <div class="text-right">
              <p
                :if={pos.unrealized_cents}
                class={[
                  "font-bold",
                  if(pos.unrealized_cents < 0, do: "text-error", else: "text-success")
                ]}
              >
                {signed_money(pos.unrealized_cents)}
              </p>
              <p :if={pos.unrealized_cents && pos.unrealized_pct} class="text-base-content/50">
                {signed_pct(pos.unrealized_pct)}
              </p>
              <%!-- A nil basis is "unavailable", NEVER $0 — zero would claim
                    the shares were free and gift the gain the whole purchase. --%>
              <p :if={is_nil(pos.unrealized_cents)} class="text-base-content/40">
                cost basis unavailable
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Upcoming earnings for held symbols (Phase 5): the thing you want to
            see BEFORE it moves you. Scoped by the sweep to what you hold; an
            empty window says so in words — silence would read as "not built". --%>
      <div :if={@all?} class="pt-3">
        <div class="flex items-center justify-between border-b border-base-content/15 pb-1">
          <p class="uppercase tracking-wide text-base-content/60">Upcoming earnings</p>
          <span id="trading-earnings-state" class="text-base-content/40">
            {as_of_label(@earnings_state)}
          </span>
        </div>
        <p :if={@earnings_state.status == :unavailable} class="pt-2 text-base-content/50">
          Earnings unavailable — the market-data sweep has not produced a readable calendar yet.
        </p>
        <p :if={@earnings_state.status == :confirmed_empty} class="pt-2 text-base-content/50">
          No earnings scheduled for your holdings in the next month{as_of_suffix(@earnings_state)}.
        </p>
        <p
          :if={@earnings_state.status == :stale and @earnings == []}
          class="pt-2 text-base-content/50"
        >
          Last calendar{as_of_suffix(@earnings_state)} listed no upcoming reports — old enough
          to re-check.
        </p>
        <div :if={@earnings != []} class="flex flex-wrap gap-x-4 gap-y-1 pt-2">
          <p :for={report <- @earnings} class="whitespace-nowrap">
            <button
              type="button"
              phx-click="trading_view_symbol"
              phx-value-symbol={report.symbol}
              class="font-bold underline decoration-base-content/30 underline-offset-2 hover:bg-base-content/5"
            >
              {report.symbol}
            </button>
            <span class="text-base-content/70">reports {earnings_when(report.date)}</span>
            <span :if={report.timing} class="text-base-content/50">
              {if report.timing == "am", do: "before open", else: "after close"}
            </span>
          </p>
        </div>
      </div>

      <%!-- The combined view has no single account to detail, so it lists them
            instead of pretending one of them is "the" account. --%>
      <div :if={@all?} class="space-y-1 pt-3">
        <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
          Accounts
        </p>
        <div :for={acct <- @accounts} class="flex items-center gap-2 py-1">
          <button
            type="button"
            phx-click="trading_select_account"
            phx-value-id={acct["id"]}
            class="flex min-w-0 flex-1 items-center justify-between gap-2 text-left hover:bg-base-content/5"
          >
            <span class={[
              "truncate font-bold",
              Enum.member?(@excluded, Trading.account_key(acct)) &&
                "text-base-content/40 line-through"
            ]}>
              {acct["label"]}
            </span>
            <span class="text-base-content/60">{acct["id"]}</span>
            <span class={[
              "text-right",
              if(Enum.member?(@excluded, Trading.account_key(acct)),
                do: "text-base-content/40",
                else: "text-base-content/80"
              )
            ]}>
              {money(acct["value"])}
            </span>
          </button>
          <button
            :if={is_binary(Trading.account_key(acct))}
            type="button"
            phx-click="trading_toggle_excluded"
            phx-value-id={Trading.account_key(acct)}
            aria-pressed={Enum.member?(@excluded, Trading.account_key(acct))}
            title={
              if Enum.member?(@excluded, Trading.account_key(acct)),
                do: "Count this account in the total again",
                else: "Leave this account out of the total (its own chart is unaffected)"
            }
            class="shrink-0 border-2 border-base-content/25 px-1.5 py-0.5 uppercase tracking-wide transition hover:bg-base-content/10"
          >
            {if Enum.member?(@excluded, Trading.account_key(acct)), do: "Include", else: "Exclude"}
          </button>
          <span
            :if={is_nil(Trading.account_key(acct))}
            class="shrink-0 border border-error/50 px-1.5 py-0.5 font-bold uppercase text-error"
            title="This account shares its last four digits with another account. Detail and ledger actions are disabled to prevent cross-account data."
          >
            Ambiguous ID
          </span>
        </div>
      </div>

      <div :if={@selected} class="space-y-5 pt-3">
        <div class="flex items-center justify-between border-b border-base-content/15 pb-1">
          <span class="text-base-content/60">{@selected["id"]}</span>
          <span class={[
            "border px-1.5 py-0.5 font-bold uppercase tracking-wide",
            if(@selected["agentic"],
              do: "border-warning/60 text-warning",
              else: "border-base-content/30 text-base-content/60"
            )
          ]}>
            {if @selected["agentic"],
              do: "Agentic account · writes disabled",
              else: "Read-only account"}
          </span>
        </div>

        <div class="grid grid-cols-3 gap-2">
          <div>
            <p class="ic-stat-n text-3xl">{money(@selected["value"])}</p>
            <p class="uppercase tracking-wide text-base-content/60">Account value</p>
          </div>
          <div class="pt-1">
            <p class="text-lg font-bold">{money(@selected["cash"])}</p>
            <p class="uppercase text-base-content/60">Cash</p>
          </div>
          <div class="pt-1">
            <p class="text-lg font-bold">{money(@selected["buying_power"])}</p>
            <p class="uppercase text-base-content/60">Buying power</p>
          </div>
        </div>

        <%!-- Allocation: one measure (value) per symbol — single-hue thin bars,
              direct labels in text tokens, no legend (single series). --%>
        <div>
          <div class="flex items-center justify-between border-b border-base-content/15 pb-1">
            <p class="uppercase tracking-wide text-base-content/60">Positions</p>
            <span id="trading-detail-state" class="text-base-content/40">
              {as_of_label(@detail_dataset_state)}
            </span>
          </div>
          <%!-- Distinct facts get distinct lines. "Can't read it",
                "haven't asked yet", "asked and it failed", and "there is
                nothing to read" must never share wording — the whole reason
                holdings load separately is that the first three are now
                common states. --%>
          <p :if={@detail_state == :unsupported} class="pt-2 text-base-content/50">
            Holdings unavailable — the Robinhood agent tools expose no
            positions for this account type. The value above is still real.
          </p>
          <p :if={@detail_state == :ambiguous} class="pt-2 font-bold text-error">
            Holdings disabled — this account shares its last four digits with
            another account. Buster Claw will not guess which account the broker tools mean.
          </p>
          <p :if={@detail_state == :loading} class="pt-2 text-base-content/60">
            Loading holdings…
          </p>
          <%!-- Retry hits stage 2 only. The Refresh button below re-runs stage 1
                too, which is ~28s of work nobody asked for when the balances on
                screen are fine and only the holdings run failed. --%>
          <div :if={match?({:error, _}, @detail_state)} class="flex items-center gap-2 pt-2">
            <p class="font-bold text-error">
              Holdings failed to load: {detail_error(@detail_state)}
            </p>
            <button
              type="button"
              phx-click="trading_retry_detail"
              class="border-2 border-base-content/40 px-2 py-0.5 font-bold uppercase tracking-wide transition hover:bg-base-content/10"
            >
              Retry
            </button>
          </div>
          <p
            :if={@detail_state == :empty and @detail_dataset_state.status == :confirmed_empty}
            class="pt-2 text-base-content/50"
          >
            No positions — the account is all cash{as_of_suffix(@detail_dataset_state)}.
          </p>
          <p
            :if={@detail_state == :empty and @detail_dataset_state.status == :stale}
            class="pt-2 text-base-content/50"
          >
            Last read{as_of_suffix(@detail_dataset_state)} showed no positions — old enough to
            refresh before calling the account all cash.
          </p>
          <div :if={@detail_state == :loaded} class="space-y-2 pt-2">
            <div
              :for={pos <- sorted_positions(@selected)}
              class="grid grid-cols-[5rem_minmax(0,1fr)_6rem] items-center gap-2"
              title={"#{pos["symbol"]}: #{pos["quantity"]} worth #{money(pos["value"])}"}
            >
              <span class="truncate font-bold">{pos["symbol"]}</span>
              <div class="h-2.5 w-full rounded-xs bg-base-content/10">
                <div
                  class="h-full rounded-xs bg-primary"
                  style={"width: #{bar_width(pos, @selected)}%"}
                >
                </div>
              </div>
              <span class="text-right text-base-content/80">{money(pos["value"])}</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- Recent activity (Phase 5): the per-account trades list, promoted to
            one shared panel. On the combined view it merges every account whose
            holdings are loaded and SAYS when that is only some of them — a
            partial merge presented as the whole would hide trades by omission.
            Side is written (BUY/SELL), never carried by color alone. --%>
      <div :if={@snap} class="pt-3">
        <div class="flex items-center justify-between border-b border-base-content/15 pb-1">
          <p class="uppercase tracking-wide text-base-content/60">Recent activity</p>
          <div class="text-right text-base-content/40">
            <p id="trading-activity-state">{as_of_label(@activity.state)}</p>
            <p :if={@activity.note}>{@activity.note}</p>
          </div>
        </div>
        <p
          :if={@activity.state.status == :unavailable and @activity.orders == []}
          class="pt-2 text-base-content/50"
        >
          Trade history unavailable — load an account's holdings to request its order history.
        </p>
        <p :if={@activity.state.status == :confirmed_empty} class="pt-2 text-base-content/50">
          No trades{as_of_suffix(@activity.state)}.
        </p>
        <p
          :if={@activity.state.status == :stale and @activity.orders == []}
          class="pt-2 text-base-content/50"
        >
          Last read{as_of_suffix(@activity.state)} showed no trades — old enough to re-check.
        </p>
        <%= for {section, rows} <- activity_order_sections(@activity.orders) do %>
          <div :if={rows != []} class="pt-2">
            <p class="pb-1 font-bold uppercase tracking-wide text-base-content/50">{section}</p>
            <div class="divide-y divide-base-content/10">
              <div
                :for={{order, account_label} <- rows}
                class="grid grid-cols-[3.5rem_4.5rem_minmax(0,1fr)_auto] items-center gap-2 py-1.5"
              >
                <span class={[
                  "border px-1.5 py-0.5 text-center font-bold uppercase",
                  order_side_class(order["side"])
                ]}>
                  {order["side"] || "?"}
                </span>
                <span class="font-bold">{order["symbol"]}</span>
                <span class="truncate text-base-content/70">
                  {order["quantity"]} @ {money(order["price"])}
                  <span class="text-base-content/50">· {order["state"]} · {account_label}</span>
                </span>
                <span class="text-right text-base-content/50">{order_when(order)}</span>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Marked transfers, when there are any. A section that exists only
              to report its own emptiness is chrome; the flows matter because
              they change the gain math, and that is worth a line ONLY when
              some exist. --%>
        <div :if={@transfer_activity.rows != []} class="border-t border-base-content/10 pt-2">
          <p class="font-bold uppercase tracking-wide text-base-content/50">
            Marked transfers
          </p>
          <p
            :for={flow <- @transfer_activity.rows}
            class="flex items-center justify-between gap-3 py-1 text-base-content/70"
          >
            <span>{flow.kind} · account {flow.account_key}</span>
            <span>{signed_money(flow.amount_cents)} · {Date.to_iso8601(flow.occurred_on)}</span>
          </p>
        </div>
      </div>

      <p :if={is_nil(@snap) and not match?({:loading, _}, @account)} class="pt-3 text-base-content/60">
        No snapshot yet — refresh to load your accounts.
      </p>
      <p :if={is_nil(@snap) and match?({:loading, _}, @account)} class="pt-3 text-base-content/60">
        Loading accounts…
      </p>
      <p :if={match?({:error, _, _}, @account)} class="pt-3 font-bold text-error">
        Refresh failed: {card_error(@account)}
      </p>

      <div class="mt-auto flex items-center justify-between gap-2 border-t-2 border-base-content/20 pt-2">
        <span id="trading-account-state" class="text-base-content/50">
          {as_of_label(@account_state)}
        </span>
        <button
          type="button"
          phx-click="trading_refresh"
          disabled={match?({:loading, _}, @account)}
          class="border-2 border-base-content/40 px-3 py-1 font-bold uppercase tracking-wide transition hover:bg-base-content/10 disabled:opacity-50"
        >
          {if match?({:loading, _}, @account), do: "Refreshing…", else: "Refresh"}
        </button>
      </div>
    </aside>
    """
  end

  # Collapse (account, in-flight stage-2 state) into the one thing the template
  # renders. Order matters: unreadable beats in-flight beats failed beats
  # loaded, because an account with no positions tool is never "loading".
  defp detail_state(nil, _detail), do: :unsupported

  defp detail_state(%{"holdings_supported" => false}, _detail), do: :unsupported
  defp detail_state(%{"identity_ambiguous" => true}, _detail), do: :ambiguous

  defp detail_state(account, detail) do
    id = account["id"]

    case detail do
      {:loading, ^id} ->
        :loading

      {:error, ^id, reason} ->
        {:error, reason}

      _ ->
        cond do
          not Trading.detail_loaded?(account) -> :loading
          sorted_positions(account) == [] -> :empty
          true -> :loaded
        end
    end
  end

  defp account_dataset_state(nil),
    do: DataState.unavailable(:not_loaded, source: :brokerage_accounts)

  defp account_dataset_state({:loading, prev}) do
    DataState.loading(prev,
      as_of: snapshot_fetched_at(prev),
      source: :brokerage_accounts
    )
  end

  defp account_dataset_state({:ok, snap}) do
    DataState.cached(snap, Trading.snapshot_stale?(snap),
      as_of: snapshot_fetched_at(snap),
      source: :brokerage_accounts
    )
  end

  defp account_dataset_state({:error, reason, nil}),
    do: DataState.unavailable(reason, source: :brokerage_accounts)

  defp account_dataset_state({:error, reason, prev}) do
    DataState.stale(prev,
      as_of: snapshot_fetched_at(prev),
      reason: reason,
      source: :brokerage_accounts
    )
  end

  defp detail_dataset_state(_account, :unsupported),
    do: DataState.unavailable(:unsupported, source: :brokerage_positions)

  defp detail_dataset_state(_account, :ambiguous),
    do: DataState.unavailable(:ambiguous_identity, source: :brokerage_positions)

  defp detail_dataset_state(account, :loading) do
    DataState.loading(nil,
      as_of: detail_fetched_at(account),
      source: :brokerage_positions
    )
  end

  defp detail_dataset_state(_account, {:error, reason}),
    do: DataState.unavailable(reason, source: :brokerage_positions)

  defp detail_dataset_state(account, state) when state in [:empty, :loaded] do
    rows = sorted_positions(account)
    as_of = detail_fetched_at(account)
    stale? = datetime_stale?(as_of)

    if state == :empty and not stale? do
      DataState.confirmed_empty(as_of: as_of, source: :brokerage_positions)
    else
      DataState.cached(rows, stale?,
        as_of: as_of,
        source: :brokerage_positions
      )
    end
  end

  defp snapshot_fetched_at(%{"fetched_at" => stamp}) when is_binary(stamp),
    do: parse_datetime(stamp)

  defp snapshot_fetched_at(_snap), do: nil

  defp detail_fetched_at(%{"detail_at" => stamp}) when is_binary(stamp),
    do: parse_datetime(stamp)

  defp detail_fetched_at(_account), do: nil

  defp detail_error({:error, :broker_tools_unavailable}),
    do: "Robinhood tools unavailable — run `claude mcp login robinhood`"

  defp detail_error({:error, {:robinhood, msg}}), do: msg
  defp detail_error({:error, :bad_snapshot}), do: "unreadable response"
  defp detail_error({:error, :unidentifiable_account}), do: "account number unavailable"
  defp detail_error({:error, :ambiguous_account}), do: "account identity is ambiguous"
  defp detail_error({:error, {:agent_exit, status}}), do: "agent exited #{status}"
  defp detail_error({:error, :no_agent_cli}), do: "Claude Code CLI not found"
  defp detail_error(_state), do: "agent run failed"

  # The headline total must agree with the chart it sits above. Once an account
  # is excluded, summing every account would show a number the line never draws.
  defp included_total(snap, excluded) do
    snap
    |> Trading.accounts()
    |> Enum.reject(&(Trading.account_key(&1) in excluded))
    |> Enum.map(& &1["value"])
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  defp money(v) when is_number(v), do: "$" <> :erlang.float_to_binary(v * 1.0, decimals: 2)
  defp money(_v), do: "—"

  # Cents to a signed dollar string. The sign is WRITTEN, never left to color —
  # the same rule the buy/sell chips follow.
  defp signed_money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: "+"
    sign <> money(abs(cents) / 100)
  end

  defp signed_money(_cents), do: "—"

  # " (+1.40%)" — appended to the day-change dollars; empty when the base was
  # zero and no percentage exists.
  defp pct_suffix(nil), do: ""
  defp pct_suffix(pct), do: " (#{signed_pct(pct)})"

  defp signed_pct(pct) when is_number(pct) do
    sign = if pct < 0, do: "-", else: "+"
    sign <> :erlang.float_to_binary(abs(pct) * 1.0, decimals: 2) <> "%"
  end

  # The activity panel's rows: `:hidden`, or %{orders: [{order, account_label}],
  # note: nil | "…"}. Selected view shows that account's orders under the same
  # gating its holdings use; the combined view merges every LOADED account and
  # names the gap when some aren't.
  defp activity_rows(accounts, excluded, nil = _selected, _detail_state) do
    eligible =
      accounts
      |> Enum.filter(
        &(&1["holdings_supported"] and is_binary(Trading.account_key(&1)) and
            Trading.account_key(&1) not in excluded)
      )

    loaded = Enum.filter(eligible, &Trading.detail_loaded?/1)

    orders =
      loaded
      |> Enum.flat_map(fn account ->
        account["orders"]
        |> List.wrap()
        |> Enum.map(&{&1, account["label"]})
      end)
      |> Enum.sort_by(fn {order, _label} -> order["placed_at"] || "" end, :desc)
      |> Enum.take(8)

    cond do
      eligible == [] ->
        %{
          orders: [],
          note: "no supported included accounts",
          state: DataState.unavailable(:no_supported_accounts, source: :brokerage_orders)
        }

      loaded == [] ->
        %{
          orders: [],
          note: "0 of #{length(eligible)} accounts loaded",
          state: DataState.unavailable(:not_loaded, source: :brokerage_orders)
        }

      length(loaded) < length(eligible) ->
        %{
          orders: orders,
          note: "partial · #{length(loaded)} of #{length(eligible)} accounts",
          state:
            DataState.unavailable(:partial,
              data: orders,
              as_of: oldest_detail_at(loaded),
              source: :brokerage_orders
            )
        }

      true ->
        %{orders: orders, note: nil, state: activity_dataset_state(orders, loaded)}
    end
  end

  defp activity_rows(_accounts, _excluded, selected, detail_state) do
    cond do
      detail_state == :loading ->
        %{
          orders: [],
          note: "loading selected account",
          state: DataState.loading(nil, source: :brokerage_orders)
        }

      detail_state in [:unsupported, :ambiguous] or match?({:error, _}, detail_state) ->
        %{
          orders: [],
          note: "selected account order history unavailable",
          state: DataState.unavailable(:not_readable, source: :brokerage_orders)
        }

      true ->
        orders = selected["orders"] |> List.wrap() |> Enum.map(&{&1, selected["label"]})

        %{
          orders: orders,
          note: nil,
          state: activity_dataset_state(orders, [selected])
        }
    end
  end

  defp activity_dataset_state(orders, accounts) do
    as_of = oldest_detail_at(accounts)
    stale? = datetime_stale?(as_of)

    if orders == [] and not stale? do
      DataState.confirmed_empty(as_of: as_of, source: :brokerage_orders)
    else
      DataState.cached(orders, stale?, as_of: as_of, source: :brokerage_orders)
    end
  end

  defp oldest_detail_at(accounts) do
    accounts
    |> Enum.map(&detail_fetched_at/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> Enum.min(dates, DateTime)
    end
  end

  defp activity_order_sections(orders) do
    {fills, other} =
      Enum.split_with(orders, fn {order, _account_label} -> order["state"] == "filled" end)

    [
      {"Orders (not filled)", other},
      {"Fills (from filled-order status)", fills}
    ]
  end

  defp transfer_activity(accounts, excluded, selected) do
    keys =
      case selected do
        nil ->
          accounts
          |> Enum.map(&Trading.account_key/1)
          |> Enum.reject(&(is_nil(&1) or &1 in excluded))

        account ->
          List.wrap(Trading.account_key(account))
      end

    if keys == [] do
      %{
        rows: [],
        state: DataState.unavailable(:no_identifiable_accounts, source: :manual_transfer_ledger)
      }
    else
      rows =
        Portfolio.all_flows()
        |> Enum.filter(&(&1.account_key in keys))
        |> Enum.sort_by(& &1.occurred_on, {:desc, Date})
        |> Enum.take(8)

      state =
        case rows do
          [] ->
            DataState.confirmed_empty(source: :manual_transfer_ledger)

          [latest | _] ->
            DataState.fresh(rows,
              as_of: latest.occurred_on,
              source: :manual_transfer_ledger
            )
        end

      %{rows: rows, state: state}
    end
  end

  defp earnings_when(%Date{} = date) do
    today = BusterClaw.MarketCalendar.today()

    case Date.diff(date, today) do
      0 -> "today"
      1 -> "tomorrow"
      _ -> Elixir.Calendar.strftime(date, "%a %b %-d")
    end
  end

  defp money_cents(cents) when is_integer(cents), do: money(cents / 100)
  defp money_cents(_cents), do: "—"

  # Fractional shares, floats for display only — trimmed so 0.1 + 0.2 never
  # renders its float dust.
  defp qty(quantity) when is_float(quantity) do
    if quantity == trunc(quantity),
      do: Integer.to_string(trunc(quantity)),
      else: quantity |> Float.round(4) |> Float.to_string()
  end

  defp qty(quantity), do: to_string(quantity)

  defp position_day_class(nil), do: "text-base-content/40"
  defp position_day_class(pct) when pct < 0, do: "text-error"
  defp position_day_class(_pct), do: "text-success"

  # An index level, not a dollar amount — no currency mark.
  defp index_price(price) when is_number(price),
    do: :erlang.float_to_binary(price * 1.0, decimals: 2)

  defp index_price(_price), do: "—"

  defp index_change(nil), do: "—"
  defp index_change(pct), do: signed_pct(pct)

  defp index_change_class(nil), do: "text-base-content/40"
  defp index_change_class(pct) when pct < 0, do: "text-error"
  defp index_change_class(_pct), do: "text-success"

  defp sorted_positions(%{"positions" => positions}),
    do: Enum.sort_by(List.wrap(positions), &(-position_value(&1)))

  defp sorted_positions(_account), do: []

  # Bar length as a % of the largest position IN THAT ACCOUNT (allocation is
  # per-account — scaling a Roth holding against an Investing holding would
  # compare two things the user never asked to compare). Guarded so a
  # zero/garbage value can't divide by zero or overflow the track.
  defp bar_width(pos, account) do
    max =
      account
      |> sorted_positions()
      |> Enum.map(&position_value/1)
      |> Enum.max(fn -> 0 end)

    if max > 0, do: Float.round(position_value(pos) / max * 100, 1), else: 0
  end

  defp position_value(%{"value" => v}) when is_number(v) and v > 0, do: v
  defp position_value(_pos), do: 0

  # Buy/sell chips: status colors validated vs both surfaces (CVD ΔE 9.7 dark /
  # 7.4 light); the written BUY/SELL word is the required secondary encoding.
  defp order_side_class("buy"), do: "border-success/50 text-success"
  defp order_side_class("sell"), do: "border-error/50 text-error"
  defp order_side_class(_side), do: "border-base-content/30 text-base-content/60"

  defp order_when(%{"placed_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> relative_time(at)
      _ -> ""
    end
  end

  defp order_when(_order), do: ""

  # The 07-28 failure mode gets its own line: the run answered, it just answered
  # without ever reaching the broker. "agent run failed" would understate it.
  defp card_error({:error, :broker_tools_unavailable, _prev}),
    do: "Robinhood tools unavailable — run `claude mcp login robinhood`"

  defp card_error({:error, {:robinhood, msg}, _prev}), do: msg
  defp card_error({:error, :bad_snapshot, _prev}), do: "unreadable snapshot"
  defp card_error({:error, {:agent_exit, status}, _prev}), do: "agent exited #{status}"
  defp card_error({:error, :no_agent_cli, _prev}), do: "Claude Code CLI not found"
  defp card_error({:error, _reason, _prev}), do: "agent run failed"

  # The as-of IS the status line. An age ("as of 3h") carries everything a
  # `stale` badge would, without asking the user to learn a second vocabulary —
  # and it degrades gracefully, where a badge that is on permanently (which
  # `stale` was, at a 15-minute threshold against data refreshed by an explicit
  # agent run) stops being read at all.
  #
  # The distinctions a timestamp genuinely cannot carry — "we asked and got
  # nothing back" versus "we never asked" — are the panel's own empty-state
  # sentence, one line lower. That is the right place for them: they only matter
  # when there is nothing else on screen.
  defp as_of_label(%DataState{status: :loading}), do: "updating…"
  defp as_of_label(%DataState{status: :unavailable}), do: ""
  defp as_of_label(%DataState{as_of: nil}), do: ""
  defp as_of_label(%DataState{as_of: as_of}), do: "as of #{format_data_time(as_of)}"

  # Parenthetical for an empty-state sentence, where the age qualifies a claim
  # ("no positions — as of when?") rather than labelling a panel.
  defp as_of_suffix(%DataState{as_of: nil}), do: ""
  defp as_of_suffix(%DataState{as_of: as_of}), do: " (as of #{format_data_time(as_of)})"

  defp format_data_time(%DateTime{} = at), do: relative_time(at)
  defp format_data_time(%Date{} = day), do: Date.to_iso8601(day)

  defp parse_datetime(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp datetime_stale?(nil), do: true

  defp datetime_stale?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) >= @holdings_stale_min

  # A coarse relative timestamp ("3m", "2h", "5d"); older than a week falls back
  # to a short date. Stamps are UTC; so is utc_now.
  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d"
      true -> Elixir.Calendar.strftime(dt, "%b %-d")
    end
  end

  defp trading_cli_missing? do
    not match?({:ok, {:claude, _path}}, BusterClaw.AgentRunner.detect())
  end
end
