defmodule BusterClaw.ChartBuilder do
  @moduledoc """
  The confined authoring profile and bounded cached-data snapshot for a
  `chartbuild` Trading conversation.

  Chart Build does not receive browser, shell, filesystem, or broker tools. The
  model gets an immutable snapshot of the app's portfolio ledger and cached
  daily closes when its conversation process starts, then returns a fenced SVG.
  This keeps an iteration to one chat run and makes a live broker read impossible
  by construction.

  ## The one thing it *does* get: web search

  Added 08-03 (`CHART_BUILD_WEB_DATA_ROADMAP` Phase 1). Chart Build is the app's
  data-research surface now, so it can look things up — but under a rule that is
  the whole reason the capability is shippable here:

  > **The model may look things up. It may not transcribe what it finds onto a
  > chart.**

  Search is for *discovery*: what a series is called, who publishes it, what
  units it is in, whether it exists at all. Numbers that get **plotted** come
  from `CACHED_DATA` or from `ChartBuilder.Fetch` — fetched by us, from a named
  source, with an `as_of`.

  That split is not fussiness. This renderer is freehand: the model emits SVG
  coordinates directly and nothing verifies the arithmetic, which is why every
  result already ships labelled *Drawn by AI · not computed*. That label honestly
  covers one failure mode — mis-plotting numbers it was given. A model
  transcribing figures off a web page adds a second, independent one, and the
  label does not cover it. Two uncorrelated ways to be wrong, one warning, on a
  chart about money.

  `WebFetch` is denied (it reaches loopback — see `AgentToolPolicy`), so the
  model sees search results rather than whole pages. That shrinks the honesty
  risk for free: a snippet is a much weaker thing to transcribe a series off
  than a fetched page.
  """

  alias BusterClaw.{AgentToolPolicy, MarketData, Portfolio, Skills, Watchlist}
  alias BusterClaw.ChartBuilder.DataReq
  alias BusterClaw.Commands.Portfolio, as: PortfolioCommands

  @max_portfolio_points 400
  @max_symbols 25
  @max_bars_per_symbol 90

  @system_prompt """
  You are Chart Build, a chart-authoring assistant inside Buster Claw.

  Your output contract:
  - When creating or revising a chart, emit exactly one fenced ```svg block with
    one complete, self-contained <svg>...</svg> and a viewBox.
  - Put any short explanation outside the fence. Never expose or explain the raw
    SVG markup; the app removes the fence from chat and renders it above you.
  - Use no scripts, event handlers, foreignObject, external URLs, external fonts,
    or image references. The entire SVG must be declarative and self-contained.
  - Keep the SVG legible from 360px wide through a desktop panel. Prefer a
    1200x640 viewBox, generous margins, direct labels, and high contrast.

  Truthfulness rules:
  - This first renderer is freehand. The app labels every result "Drawn by AI —
    not computed". Never describe the geometry as independently verified.
  - Plot only numbers present in CACHED_DATA below, delivered to you by the app,
    or supplied by the operator. Never invent, interpolate, forward-fill, or
    silently smooth missing values.
  - Include zero for quantitative bar axes. For line/scatter charts, label the
    actual domain and never imply an omitted baseline.
  - Dates use their real spacing. Missing dates are gaps: break a line rather
    than connecting across an unmeasured interval.
  - Axis ticks and labels must agree with the values you plotted. Show units and
    name the measure.
  - State thin coverage plainly in the prose and in the chart subtitle (for
    example, "4 cached observations"). A smaller honest chart beats a confident
    fictional one.

  What you can draw, and how to say so:
  - CACHED_DATA.daily_closes is a PREVIEW, truncated per symbol. CACHED_DATA.coverage
    states what the cache really holds for each one: cached_bars, included_bars,
    truncated, first_cached, last_cached. Read coverage before saying how much
    history exists — the preview is not the cache, and "that is all there is" is
    a claim you can only make from coverage.
  - When coverage says truncated, you can have the rest. Ask for it and plot the
    next turn's numbers:

      ```datareq
      {"source": "market", "series": "SPY"}
      ```

    That returns every cached bar for the symbol, so a year is drawable whenever
    coverage says a year is cached.
  - Say WHICH chart you can draw, not only which you cannot. A symbol with 250
    bars supports a year; one with six supports a week. Offer the honest window
    rather than refusing outright.
  - For a symbol with no bars: it is not tracked yet. Say that, say whether it is
    already on CACHED_DATA.watchlist (queued, its history arrives on the daily
    tick), and if it is not, name the gesture — add it to a watchlist in the
    Trading tab's left rail. Never substitute a different symbol for the one
    that was asked for.
  - Comparing symbols of different magnitudes: index each to 100 at a common
    start and say you did. Two price scales on one axis is not a comparison.

  Data boundary — read this twice; it is the rule that makes your web access
  safe to have:

    You may LOOK THINGS UP. You may not TRANSCRIBE what you find onto a chart.

  - You have web SEARCH. Use it to find out what a series is called, who
    publishes it, what units it is in, how often it is measured, and whether it
    exists at all. That is research, and it is what you are for.
  - You may NOT plot a number you read in a search result. Not "prefer not to" —
    may not. A figure you transcribed has not been through the app's fetch path,
    carries no source and no as-of, and this chart is already labelled "Drawn by
    AI — not computed". One unverified layer is the honest cost of a freehand
    renderer. Two is a chart that lies twice and warns once.
  - You do NOT have web fetch. You cannot open a page; you see search results.
    Say that plainly rather than promising to go and read something.
  - You have no broker, shell, or filesystem tools, and no way to place an order.
  - When you need numbers the app does not already have, ASK THE APP FOR THEM by
    emitting exactly one fenced block of this form, and then STOP and wait:

    ```datareq
    {"source": "bls", "series": "CUUR0000SA0", "start_year": 2020, "end_year": 2026}
    ```

    The app removes the block from the conversation, fetches the series itself,
    and hands the result back as the next turn with a source and an as-of
    attached. Those figures ARE plottable — they came through the application,
    not through you.

    - `source` must be one of the sources listed under FETCHABLE_SOURCES below.
      Any other name is refused without a fetch.
    - `series` is the publisher's own series id.
    - `start_year` / `end_year` are optional.
    - One block per message. Do not draw a placeholder while you wait, and do
      not emit a datareq block in the same message as a chart.
    - If a fetch fails, the reply says why. Do not send the identical request
      again — the answer will not change. Say what is missing instead.
  - CACHED_DATA is a point-in-time local snapshot. If it cannot answer the
    request and nothing has been delivered to you, say what is missing and name
    what you would need. A smaller honest chart beats a confident fictional one,
    and refusing to draw is a complete, correct answer here.
  - Any figures the app delivers to you arrive with a source and an as-of.
    Put both in the chart's subtitle. If a delivered series covers a shorter
    span than the operator asked for, say so in the subtitle too — never label a
    chart with the range that was requested rather than the one you plotted.
  """

  @doc """
  Claude chat options for a Chart Build conversation.

  `--disallowedTools` is what actually refuses a built-in under `dontAsk`
  (measured 07-28; see `Trading.read_only_cli_args/0`), so the web capability is
  granted by *subtracting* from that list. The paired `--allowedTools` only
  stops `WebSearch` prompting — on its own it would confine nothing.
  """
  def chat_opts do
    [
      append_system_prompt: system_prompt(),
      permission_mode: "dontAsk",
      extra_cli_args: [
        "--disallowedTools",
        Enum.join(AgentToolPolicy.denied_builtins(:chartbuild), ","),
        "--allowedTools",
        Enum.join(AgentToolPolicy.web_capable_builtins(), ",")
      ]
    ]
  end

  @doc "The authoring prompt plus the current bounded cache snapshot."
  def system_prompt do
    [
      @system_prompt,
      fetchable_sources(),
      reference_playbook(),
      "CACHED_DATA (JSON):",
      Jason.encode!(cached_data())
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Rendered from the registry rather than written out here, so a source added
  # in `DataReq` is one the model immediately knows how to name. A hand-written
  # list would drift the first time the registry grew, and the failure mode is
  # the model asking for a source that exists or refusing one that does.
  defp fetchable_sources do
    lines =
      Enum.map_join(DataReq.sources(), "\n", fn {key, meta} ->
        "  - #{key} — #{meta.name}. #{meta.answers}. Series: #{meta.series_hint}."
      end)

    """
    FETCHABLE_SOURCES (valid values for a datareq `source`):

    #{lines}

    Drawable from the `market` source right now: #{drawable()}.

    `market` reads this app's own cache and NEVER triggers a broker fetch, so a
    symbol that is not listed above simply is not available — asking again will
    not change that. SPY is how to chart the S&P 500 here; it is the ETF's daily
    close, so say "S&P 500 (SPY)" rather than implying the index level itself.

    Nothing else is fetchable. If what the operator needs is not here, say so
    plainly and name the publisher you would want — do not substitute a source
    from this list that publishes something merely similar, and never chart a
    near-enough ticker in place of the one they asked for.
    """
  end

  @doc "Bounded, JSON-safe portfolio and held-symbol data available to Chart Build."
  def cached_data do
    {:ok, history} = PortfolioCommands.portfolio_history(%{"range" => "ALL"})

    positions =
      Portfolio.position_rows()
      |> Enum.take(@max_symbols)
      |> Enum.map(fn row ->
        %{
          symbol: row.symbol,
          quantity: row.quantity,
          cost_basis: dollars(row.cost_basis_cents),
          as_of: iso(row.as_of)
        }
      end)

    symbols =
      positions
      |> Enum.map(& &1.symbol)
      |> Kernel.++(MarketData.known_symbols())
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@max_symbols)

    market =
      Map.new(symbols, fn symbol ->
        bars =
          symbol
          |> MarketData.bars(@max_bars_per_symbol)
          |> Enum.map(&%{day: Date.to_iso8601(&1.bar_on), close: dollars(&1.close_cents)})

        {symbol, bars}
      end)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      portfolio: %{history | points: Enum.take(history.points, -@max_portfolio_points)},
      held_positions: positions,
      cached_market_symbols: symbols,
      daily_closes: market,
      # What the cache actually holds, beside what this snapshot could carry.
      # Without it the model reads a 90-bar preview as the whole cache and says
      # so confidently — true for a symbol with 65 bars, false for one with 254,
      # and indistinguishable from the outside. `datareq` widens it.
      coverage: coverage(symbols, market),
      # Symbols the operator asked to track. A watched symbol with no bars is
      # queued rather than missing, and that is a different sentence.
      watchlist: Watchlist.symbols(),
      limits: %{
        portfolio_points: @max_portfolio_points,
        held_symbols: @max_symbols,
        bars_per_symbol: @max_bars_per_symbol
      }
    }
  end

  # Rendered live rather than described, because "what is cached" changes as the
  # Recorder backfills. A model told the wrong list either refuses something it
  # could have drawn or promises something it cannot.
  defp drawable do
    case MarketData.chartable_symbols() do
      [] ->
        "nothing yet — the daily recorder has not filled the cache"

      symbols ->
        # Names alone let the model promise a year of a symbol holding six days.
        # Each one carries its depth so it can say WHICH chart it can draw.
        Enum.map_join(symbols, ", ", fn symbol ->
          case length(MarketData.bars(symbol)) do
            0 -> "#{symbol} (queued, no bars yet)"
            n -> "#{symbol} (#{n} bars)"
          end
        end)
    end
  end

  # Per symbol: everything cached, and how much of it this snapshot carries.
  defp coverage(symbols, market) do
    Map.new(symbols, fn symbol ->
      all = MarketData.bars(symbol)
      included = Map.get(market, symbol, [])

      {symbol,
       %{
         cached_bars: length(all),
         included_bars: length(included),
         truncated: length(all) > length(included),
         first_cached: all |> List.first() |> bar_day(),
         last_cached: all |> List.last() |> bar_day()
       }}
    end)
  end

  defp bar_day(%{bar_on: day}), do: Date.to_iso8601(day)
  defp bar_day(_none), do: nil

  defp reference_playbook do
    case Skills.load("chart-builder") do
      {:ok, %{handler_kind: :reference, body: body}} ->
        "REFERENCE PLAYBOOK:\n" <> body

      _other ->
        nil
    end
  end

  defp dollars(nil), do: nil
  defp dollars(cents) when is_integer(cents), do: Portfolio.to_dollars(cents)

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(%Date{} = value), do: Date.to_iso8601(value)
  defp iso(_value), do: nil
end
