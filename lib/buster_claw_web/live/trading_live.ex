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
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.Portfolio
  alias BusterClaw.Trading

  # The combined-total chip. A sentinel rather than nil so the selection is
  # always an explicit choice, and so it round-trips through phx-value-id.
  @all_accounts "__all__"

  # Cap the retained in-memory transcript on a long-lived tab; the persisted
  # transcript is the source of truth and is re-read on mount.
  @max_chat_messages 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chat.subscribe(Trading.conv_id())

    socket =
      socket
      |> assign(:page_title, "Trading")
      |> assign(:agent_cli_missing, match?({:error, _}, BusterClaw.AgentRunner.detect()))
      |> assign(:chat_running, Chat.running?(Trading.conv_id()))
      |> assign(:chat_thinking, if(Chat.running?(Trading.conv_id()), do: :running, else: nil))
      |> assign(:chat_queue, Chat.queue(Trading.conv_id()))
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
      |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
      |> load_chat_history()

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
  def handle_event("chat_send", %{"message" => text}, socket) do
    # Sending barges in on any reply still being spoken.
    socket = push_event(socket, "bc:stop_speak", %{})

    case String.trim(text) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, dispatch_chat(socket, trimmed)}
    end
  end

  def handle_event("cancel_queued", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {qid, ""} -> Chat.remove_queued(Trading.conv_id(), qid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("cut_run", _params, socket) do
    Chat.interrupt(Trading.conv_id())
    {:noreply, push_event(socket, "bc:stop_speak", %{})}
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
    with {:ok, day} <- Date.from_iso8601(day),
         account_key when is_binary(account_key) <- params["account_key"],
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
    if Portfolio.excluded?(key),
      do: Portfolio.include_account(key),
      else: Portfolio.exclude_account(key)

    {:noreply, load_chart(socket)}
  end

  def handle_event("trading_toggle_table", _params, socket) do
    {:noreply, update(socket, :trading_table, &(!&1))}
  end

  def handle_event("trading_select_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:trading_range, range)
     |> assign(:trading_range_pinned, true)}
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

  def handle_event("trading_retry_detail", _params, socket) do
    # Drop the error first: maybe_load_detail/1 leaves an in-flight run alone,
    # and a cleared error is what makes the panel show "Loading…" again.
    {:noreply, socket |> assign(:trading_detail, nil) |> maybe_load_detail()}
  end

  def handle_event("trading_select_account", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:trading_account_sel, id)
     |> maybe_load_detail()
     |> load_anomaly()
     |> load_chart()}
  end

  # ---------------------------------------------------------------------------
  # Chat stream (from the conversation's PubSub broadcasts)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:agent_chat, conv_id, payload}, socket) do
    if conv_id == Trading.conv_id(),
      do: {:noreply, apply_chat(socket, payload)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_chat(socket, {:status, status}) do
    socket =
      socket
      |> assign(:chat_running, status == :running)
      |> assign(:chat_thinking, if(status == :running, do: :running, else: nil))

    # A finished trading run may have moved money — re-snapshot the accounts
    # while the operator is looking at them.
    if status == :idle, do: maybe_refresh_account(socket), else: socket
  end

  defp apply_chat(socket, {:thinking, ms}), do: assign(socket, :chat_thinking, {:done, ms})
  defp apply_chat(socket, {:queue, items}), do: assign(socket, :chat_queue, items)

  defp apply_chat(socket, {:message, %{role: role, text: text}}) do
    socket
    |> maybe_speak(role, text)
    |> push_msg(role, text)
  end

  defp apply_chat(socket, _other), do: socket

  # Speak the model's replies aloud (client gates on the Voice toggle + desktop
  # app). Only `:assistant` text — never tool/meta/error lines.
  defp maybe_speak(socket, :assistant, text), do: push_event(socket, "bc:speak", %{text: text})
  defp maybe_speak(socket, _role, _text), do: socket

  defp dispatch_chat(socket, text) do
    conv_id = Trading.conv_id()

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

        Chat.ensure_started(conv_id, Trading.chat_opts())
        do_send(socket, conv_id, text)

      _other ->
        push_msg(socket, :error, "Trading requires the Claude Code CLI.")
    end
  catch
    :exit, _reason ->
      push_msg(socket, :error, "Chat backend isn't running — restart the server.")
  end

  # While a run is in flight send_message/2 queues the text (returns :ok) rather
  # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
  defp do_send(socket, conv_id, text) do
    case Chat.send_message(conv_id, text) do
      :ok -> socket
      {:error, :no_agent_cli} -> socket
      {:error, reason} -> push_msg(socket, :error, "Could not start the run: #{inspect(reason)}")
    end
  end

  defp push_msg(socket, role, text) do
    seq = socket.assigns.chat_seq + 1
    msg = %{id: seq, role: role, text: text, svg_ids: []}

    socket
    |> assign(:chat_seq, seq)
    |> stream_insert(:chat_messages, msg, limit: -@max_chat_messages)
  end

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
  defp load_chat_history(socket) do
    messages =
      Trading.conv_id()
      |> AgentTranscript.recent(limit: 200)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, i} ->
        %{id: i, role: history_role(row.role), text: row.content, svg_ids: []}
      end)

    socket
    |> stream(:chat_messages, messages, reset: true)
    |> assign(:chat_seq, length(messages))
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

  # Stage 2 lands. The id is carried through the result rather than read off the
  # socket: the user may have clicked another chip while this ran, and the data
  # belongs to the account that was asked for, not the one now on screen.
  def handle_async({:trading_detail, id}, {:ok, result}, socket) do
    case result do
      {:ok, detail} -> {:noreply, store_detail(socket, id, detail)}
      {:error, reason} -> {:noreply, assign(socket, :trading_detail, {:error, id, reason})}
    end
  end

  def handle_async({:trading_detail, id}, {:exit, reason}, socket) do
    {:noreply, assign(socket, :trading_detail, {:error, id, {:exit, reason}})}
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

    case account && Trading.last4(account) do
      nil -> {:error, :no_account}
      key -> {:ok, key}
    end
  end

  # The sign lives with the kind, so the form only ever collects a magnitude —
  # a user typing "-500" for a withdrawal must not end up with a double negative.
  defp flow_cents("not_a_transfer", _amount), do: {:ok, 0}

  defp flow_cents(kind, amount) when kind in ["deposit", "withdrawal"] do
    case Float.parse(to_string(amount || "")) do
      {dollars, _rest} when dollars > 0 ->
        cents = round(dollars * 100)
        {:ok, if(kind == "withdrawal", do: -cents, else: cents)}

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
    |> Enum.map(&Trading.last4/1)
    |> Enum.reject(&is_nil/1)
  end

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
    |> assign(:trading_coverage, Portfolio.backfill_coverage())
    |> maybe_default_range(series)
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

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <section class="flex min-h-0 flex-1 flex-col gap-2 p-4">
        <div
          id="trading-split"
          phx-hook="SplitResizer"
          data-resize-var="--trading-left"
          data-resize-key="bc:trading-split-ratio"
          data-resize-default="0.3"
          class="flex min-h-0 flex-1 flex-col gap-2 lg:flex-row lg:gap-0"
        >
          <div class="bc-trading-left flex min-h-0 flex-col gap-2">
            <div class="border-2 border-warning/40 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-warning">
              Real orders execute on the Robinhood agentic account — every other account is read-only
            </div>
            <%!-- First-run setup: the OAuth handshake is interactive by nature
                  (a browser window), so it happens once in a terminal — the
                  keychain tokens are then reused by every headless turn. --%>
            <div
              :if={@chat_seq == 0}
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
            <BusterClawWeb.ChatPanel.chat_panel
              messages={@streams.chat_messages}
              seq={@chat_seq}
              running={@chat_running}
              thinking={@chat_thinking}
              queue={@chat_queue}
              agent_cli_missing={@agent_cli_missing}
            />
          </div>

          <div
            data-split-divider
            title="Drag to resize"
            class="group relative hidden shrink-0 cursor-col-resize items-center justify-center lg:flex lg:w-3"
          >
            <span class="h-full w-px bg-base-content/15 transition group-hover:bg-primary"></span>
          </div>

          <div class="bc-trading-right flex min-h-0">
            <.trading_account_card
              account={@trading_account}
              selected_id={@trading_account_sel}
              detail={@trading_detail}
              anomaly={@trading_anomaly}
              series={@trading_series}
              range={@trading_range}
              coverage={@trading_coverage}
              backfilling={@trading_backfilling}
              table={@trading_table}
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # The accounts panel (right column). Shows whichever snapshot we have —
  # including a stale one under a spinner or error line — with an honest as-of
  # stamp; the truth costs an agent run, so it is never silently auto-polled.
  #
  # Every account is readable here; exactly one is writable. The chips carry
  # that distinction (ORDERS HERE / READ-ONLY) because a panel that shows four
  # accounts identically invites the assumption that the agent can trade in all
  # four.
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
      |> assign(:detail_state, detail_state(selected, assigns.detail))

    ~H"""
    <aside
      id="trading-account-card"
      class="ic-panel flex min-h-0 w-full flex-col overflow-y-auto p-4 font-mono text-xs"
    >
      <div class="flex items-center justify-between border-b-2 border-base-content/20 pb-2">
        <p class="font-bold uppercase tracking-widest">
          {cond do
            @excluded != [] -> "Included accounts"
            length(@accounts) > 1 -> "All accounts"
            true -> "Account"
          end}
        </p>
        <span :if={@snap} class="ic-stat-n text-xl">
          {money(included_total(@snap, @excluded))}
        </span>
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

      <div class="pt-3">
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
              Enum.member?(@excluded, acct["last4"]) && "text-base-content/40 line-through"
            ]}>
              {acct["label"]}
            </span>
            <span class="text-base-content/60">{acct["id"]}</span>
            <span class={[
              "text-right",
              if(Enum.member?(@excluded, acct["last4"]),
                do: "text-base-content/40",
                else: "text-base-content/80"
              )
            ]}>
              {money(acct["value"])}
            </span>
          </button>
          <button
            type="button"
            phx-click="trading_toggle_excluded"
            phx-value-id={acct["last4"]}
            aria-pressed={Enum.member?(@excluded, acct["last4"])}
            title={
              if Enum.member?(@excluded, acct["last4"]),
                do: "Count this account in the total again",
                else: "Leave this account out of the total (its own chart is unaffected)"
            }
            class="shrink-0 border-2 border-base-content/25 px-1.5 py-0.5 uppercase tracking-wide transition hover:bg-base-content/10"
          >
            {if Enum.member?(@excluded, acct["last4"]), do: "Include", else: "Exclude"}
          </button>
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
            {if @selected["agentic"], do: "Orders execute here", else: "Read-only to agent"}
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
          <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
            Positions
          </p>
          <%!-- Four distinct facts, four distinct lines. "Can't read it",
                "haven't asked yet", "asked and it failed", and "there is
                nothing to read" must never share wording — the whole reason
                holdings load separately is that the first three are now
                common states. --%>
          <p :if={@detail_state == :unsupported} class="pt-2 text-base-content/50">
            Holdings unavailable — the Robinhood agent tools expose no
            positions for this account type. The value above is still real.
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
          <p :if={@detail_state == :empty} class="pt-2 text-base-content/50">
            No positions — the account is all cash.
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

        <%!-- Trades: an event list, not a chart — side is written (BUY/SELL),
              never carried by color alone. Same stage-2 gating as positions:
              orders arrive in the same run, so they share its states. --%>
        <div :if={@detail_state not in [:unsupported, :loading]}>
          <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
            Recent trades
          </p>
          <p :if={List.wrap(@selected["orders"]) == []} class="pt-2 text-base-content/50">
            No trades yet.
          </p>
          <div :if={List.wrap(@selected["orders"]) != []} class="divide-y divide-base-content/10">
            <div
              :for={order <- List.wrap(@selected["orders"])}
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
                <span class="text-base-content/50">· {order["state"]}</span>
              </span>
              <span class="text-right text-base-content/50">{order_when(order)}</span>
            </div>
          </div>
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
        <span class="text-base-content/50">{card_asof(@snap)}</span>
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

  defp detail_error({:error, {:robinhood, msg}}), do: msg
  defp detail_error({:error, :bad_snapshot}), do: "unreadable response"
  defp detail_error({:error, :unidentifiable_account}), do: "account number unavailable"
  defp detail_error({:error, {:agent_exit, status}}), do: "agent exited #{status}"
  defp detail_error({:error, :no_agent_cli}), do: "Claude Code CLI not found"
  defp detail_error(_state), do: "agent run failed"

  # The headline total must agree with the chart it sits above. Once an account
  # is excluded, summing every account would show a number the line never draws.
  defp included_total(snap, excluded) do
    snap
    |> Trading.accounts()
    |> Enum.reject(&(Trading.last4(&1) in excluded))
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

  defp card_asof(%{"fetched_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> "as of #{relative_time(at)}"
      _ -> ""
    end
  end

  defp card_asof(_snap), do: ""

  defp card_error({:error, {:robinhood, msg}, _prev}), do: msg
  defp card_error({:error, :bad_snapshot, _prev}), do: "unreadable snapshot"
  defp card_error({:error, {:agent_exit, status}, _prev}), do: "agent exited #{status}"
  defp card_error({:error, :no_agent_cli, _prev}), do: "Claude Code CLI not found"
  defp card_error({:error, _reason, _prev}), do: "agent run failed"

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
end
