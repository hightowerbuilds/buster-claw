defmodule BusterClaw.ChartBuilder do
  @moduledoc """
  The confined authoring profile and bounded cached-data snapshot for a
  `chartbuild` Trading conversation.

  Chart Build does not receive browser, shell, filesystem, or broker tools. The
  model gets an immutable snapshot of the app's portfolio ledger and cached
  daily closes when its conversation process starts, then returns a fenced SVG.
  This keeps an iteration to one chat run and makes a live broker read impossible
  by construction.
  """

  alias BusterClaw.{AgentToolPolicy, MarketData, Portfolio, Skills}
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
  - Plot only numbers present in CACHED_DATA below or supplied by the operator.
    Never invent, interpolate, forward-fill, or silently smooth missing values.
  - Include zero for quantitative bar axes. For line/scatter charts, label the
    actual domain and never imply an omitted baseline.
  - Dates use their real spacing. Missing dates are gaps: break a line rather
    than connecting across an unmeasured interval.
  - Axis ticks and labels must agree with the values you plotted. Show units and
    name the measure.
  - State thin coverage plainly in the prose and in the chart subtitle (for
    example, "4 cached observations"). A smaller honest chart beats a confident
    fictional one.

  Data boundary:
  - You have no broker, web, shell, or filesystem tools in this conversation.
  - CACHED_DATA is a point-in-time local snapshot. If it cannot answer the
    request, say what is missing and ask the operator to provide it or refresh
    the relevant Trading data explicitly. Do not claim to fetch fresh data.
  """

  @doc "Claude chat options for a cached-only Chart Build conversation."
  def chat_opts do
    [
      append_system_prompt: system_prompt(),
      permission_mode: "dontAsk",
      extra_cli_args: ["--disallowedTools", Enum.join(AgentToolPolicy.denied_builtins(), ",")]
    ]
  end

  @doc "The authoring prompt plus the current bounded cache snapshot."
  def system_prompt do
    [@system_prompt, reference_playbook(), "CACHED_DATA (JSON):", Jason.encode!(cached_data())]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
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
      limits: %{
        portfolio_points: @max_portfolio_points,
        held_symbols: @max_symbols,
        bars_per_symbol: @max_bars_per_symbol
      }
    }
  end

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
