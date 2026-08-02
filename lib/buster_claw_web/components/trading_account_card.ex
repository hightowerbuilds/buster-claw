defmodule BusterClawWeb.TradingAccountCard do
  @moduledoc """
  The Trading page's accounts panel — the whole right column, as one component.

  Presentation only. Every event it emits (`trading_refresh`, `select_account`,
  `set_range`, the symbol-chart controls, …) is handled by `TradingLive`, which
  owns the fetch state; this module decides only how that state reads.

  The values it renders are computed by `BusterClawWeb.TradingView`, imported
  here — so what a panel is allowed to CLAIM about its data is decided in one
  place and tested without rendering anything.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.TradingView

  alias BusterClaw.Trading

  # The accounts panel (right column). Shows whichever snapshot we have —
  # including a stale one under a spinner or error line — with an honest as-of
  # stamp; the truth costs an agent run, so it is never silently auto-polled.
  #
  # Every account is readable here. Robinhood still identifies the account that
  # is Agentic-capable, but this app disables writes at the Claude tool boundary;
  # the chip says both facts so capability is never mistaken for authorization.
  attr :account, :any, required: true
  attr :selected_id, :string, required: true
  attr :all_accounts, :string, required: true
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

  def trading_account_card(assigns) do
    snap = last_snapshot(assigns.account)
    all? = assigns.selected_id == assigns.all_accounts
    selected = if all?, do: nil, else: snap && Trading.select_account(snap, assigns.selected_id)

    assigns =
      assigns
      |> assign(:snap, snap)
      |> assign(:accounts, Trading.accounts(snap))
      |> assign(:selected, selected)
      |> assign(:all?, all?)
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
              do: "Agentic · orders need your confirmation",
              else: "Read-only · not agent-enabled"}
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
end
