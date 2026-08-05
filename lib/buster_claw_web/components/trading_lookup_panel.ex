defmodule BusterClawWeb.TradingLookupPanel do
  @moduledoc """
  Chart Build's symbol lookup — quote, fundamentals, and SEC filings for one
  symbol. (It was the Research tab's panel until 08-03, when Chart Build absorbed
  the data-research job and the Research chat was deleted as redundant.)

  Everything here renders what the APP fetched (`ChartBuilder.Fetch` →
  `BusterClaw.Finance` → Finnhub and EDGAR), never anything the model typed.
  That is the point of the panel being its own surface, and it is now
  load-bearing rather than merely tidy: the Chart Build model may search the web,
  so the operator needs one region of this tab where every number demonstrably
  did not come from a model. Each dataset carries its own state and its own error
  line because each can fail alone.

  Presentation only — `TradingLive` owns the query and the fetches.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.TradingView

  alias BusterClaw.DataState

  attr :panel, :map, required: true
  attr :query, :string, required: true
  attr :matches, :list, required: true
  attr :cursor, :integer, default: nil, doc: "index of the keyboard-highlighted match"

  # Everything here is rendered from what the APP fetched — Finnhub and EDGAR
  # through `BusterClaw.Finance` — never from anything the model typed. Each
  # dataset states its own source and age because each can fail alone.
  def lookup_card(assigns) do
    ~H"""
    <aside
      id="trading-lookup-card"
      class="ic-panel flex min-h-0 w-full flex-col overflow-y-auto p-4 font-mono text-xs"
    >
      <form phx-change="lookup_search" phx-submit="lookup_search" autocomplete="off">
        <%!-- Arrow keys walk the matches, Enter opens the highlighted one, Escape
              drops the highlight. Handled in the LiveView rather than a JS hook,
              like the rail's bumper — see `move_lookup_cursor/2`. --%>
        <input
          type="text"
          name="query"
          value={@query}
          phx-keydown="lookup_key"
          role="combobox"
          aria-expanded={@matches != []}
          aria-controls="trading-lookup-matches"
          aria-activedescendant={@cursor && "trading-lookup-match-#{@cursor}"}
          placeholder="Search a ticker or company…"
          class="w-full border-2 border-base-content/25 bg-base-100 px-2 py-1.5 focus:border-primary focus:outline-none"
        />
      </form>

      <div
        :if={@matches != []}
        id="trading-lookup-matches"
        role="listbox"
        class="mt-1 divide-y divide-base-content/10 border-2 border-base-content/20"
      >
        <button
          :for={{match, index} <- Enum.with_index(@matches)}
          type="button"
          id={"trading-lookup-match-#{index}"}
          role="option"
          aria-selected={index == @cursor}
          phx-click="lookup_open"
          phx-value-symbol={match.symbol}
          class={[
            "flex w-full items-baseline gap-2 px-2 py-1.5 text-left transition hover:bg-base-content/10",
            index == @cursor && "bg-primary/20 ring-1 ring-inset ring-primary"
          ]}
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
            phx-click="lookup_clear"
            class="uppercase tracking-wide text-base-content/50 hover:text-base-content"
          >
            Clear
          </button>
        </div>

        <%!-- Quote. The delay is stated every time: a free-tier print is not a
              live one, and a number without its age invites being read as now. --%>
        <div class="pt-3">
          <div :if={@panel.quote.status == :fresh} class="flex items-baseline gap-3">
            <p class="text-2xl font-black">{lookup_price(@panel.quote.data)}</p>
            <p class={lookup_change_class(@panel.quote.data)}>
              {lookup_change(@panel.quote.data)}
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
            {lookup_edgar_error(@panel.fundamentals, @panel.symbol)}
          </p>
          <div :if={@panel.fundamentals.status == :fresh} class="pt-2">
            <p
              :for={{label, value} <- lookup_facts(@panel.fundamentals.data)}
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
            {lookup_edgar_error(@panel.filings, @panel.symbol)}
          </p>
          <div :if={@panel.filings.status == :fresh} class="divide-y divide-base-content/10 pt-1">
            <p
              :for={filing <- lookup_filings(@panel.filings.data)}
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

  # --- Lookup renderers ---
  #
  # Every one of these tolerates a nil: EDGAR returns a fact map whose values are
  # individually nil when a company never filed that concept, and Finnhub returns
  # zeros for a symbol it does not cover. A dash is the honest render for both —
  # never a 0, which would read as a real measurement of nothing.

  defp lookup_price(%{price: price}) when is_number(price) and price > 0,
    do: "$" <> :erlang.float_to_binary(price * 1.0, decimals: 2)

  defp lookup_price(_quote), do: "—"

  defp lookup_change(%{percent_change: pct, change: change})
       when is_number(pct) and is_number(change) do
    "#{signed_pct(pct)} (#{signed_money(round(change * 100))})"
  end

  defp lookup_change(_quote), do: "—"

  defp lookup_change_class(%{percent_change: pct}) when is_number(pct) and pct > 0,
    do: "font-bold text-success"

  defp lookup_change_class(%{percent_change: pct}) when is_number(pct) and pct < 0,
    do: "font-bold text-error"

  defp lookup_change_class(_quote), do: "text-base-content/60"

  @fundamental_labels [
    revenue: "Revenue",
    net_income: "Net income",
    assets: "Assets",
    liabilities: "Liabilities",
    stockholders_equity: "Shareholders' equity"
  ]

  defp lookup_facts(%{facts: facts}) when is_map(facts) do
    Enum.map(@fundamental_labels, fn {key, label} ->
      {label, lookup_fact_value(Map.get(facts, key))}
    end)
  end

  defp lookup_facts(_data), do: []

  # The period is part of the figure. A revenue number with no year attached is
  # a number the reader has to guess the meaning of.
  defp lookup_fact_value(%{value: value, as_of: as_of}) when is_number(value) do
    "#{lookup_big_money(value)}#{if as_of, do: " (#{as_of})", else: ""}"
  end

  defp lookup_fact_value(_fact), do: "—"

  defp lookup_big_money(value) when is_number(value) do
    abs = abs(value)

    cond do
      abs >= 1_000_000_000 -> "$#{Float.round(value / 1_000_000_000, 2)}B"
      abs >= 1_000_000 -> "$#{Float.round(value / 1_000_000, 1)}M"
      true -> "$#{round(value)}"
    end
  end

  defp lookup_filings(%{filings: filings}) when is_list(filings) do
    filings
    |> Enum.take(8)
    |> Enum.map(&%{form: &1.form || "—", filed_on: &1.filing_date || "—"})
  end

  defp lookup_filings(_data), do: []

  defp lookup_edgar_error(%DataState{reason: {:unknown_symbol, _sym}}, symbol),
    do: "SEC EDGAR has no company matching #{symbol}."

  defp lookup_edgar_error(%DataState{reason: :no_symbol}, _symbol),
    do: "Search a ticker to load this."

  defp lookup_edgar_error(_state, _symbol),
    do: "SEC EDGAR could not be reached."
end
