defmodule BusterClawWeb.PortfolioChart do
  @moduledoc """
  The cumulative gain/loss chart (PORTFOLIO_HISTORY_ROADMAP Phase 4).

  Server-rendered SVG. No charting dependency: the data already lives on the
  server, LiveView already re-renders, and the CSP forbids fetching a library
  anyway.

  ## What it draws

  One series — cumulative dollars gained or lost — so there is no categorical
  palette and no legend of series identity. The only legend is the one that
  matters: which stretch of the line is which **measure**.

    * **Dashed, muted** — realized P&L from Robinhood, before we started
      recording. Closed trades only; blind to gains still being held.
    * **Solid, gain/loss colored** — computed from our own daily readings, which
      see both realized and unrealized.

  They share a y-axis honestly because they share a unit *and* a meaning
  (dollars gained, accumulating). What changes at the seam is completeness, and
  that is what the caption says.

  ## Two rules the geometry enforces

  **Gaps are gaps.** The x-axis is a real date scale, not point indices, so a
  missing week occupies a week of width. Consecutive readings more than one
  trading day apart start a new path segment — the line does not span the hole,
  because connecting across it would draw a trend through days nobody measured.

  **Zero is always in frame.** A gain chart that crops the zero line lets a
  small loss look like a rout. The y-domain always includes 0, and the baseline
  is drawn.

  Text lives in HTML around the plot, never inside the SVG: the viewBox stretches
  to the panel width and any embedded text would stretch with it.
  """
  use BusterClawWeb, :html

  alias BusterClaw.MarketCalendar

  # The plot's coordinate space. Rendered with preserveAspectRatio="none" so it
  # fills whatever width the panel gives it; nothing inside carries text.
  @width 720
  @height 200
  # Keeps a line that touches the domain edge from being clipped by its stroke.
  @pad 6
  # Beyond this many points, marks stop being individually legible.
  @max_dots 60

  @ranges [
    {"1W", 7},
    {"1M", 31},
    {"3M", 93},
    {"1Y", 366},
    {"ALL", nil}
  ]

  def ranges, do: @ranges

  attr :series, :list, required: true
  attr :range, :string, required: true
  attr :label, :string, required: true
  attr :coverage, :map, default: nil
  attr :backfilling, :boolean, default: false
  attr :table, :boolean, default: false

  def portfolio_chart(assigns) do
    windowed = assigns.series |> window(assigns.range) |> rebase(assigns.series)

    assigns =
      assigns
      |> assign(:points, windowed)
      |> assign(:granularity, granularity(windowed))
      |> assign(:plotted, downsample(windowed))

    assigns =
      assigns
      |> assign(:segments, segments(assigns.plotted))
      |> assign(:geometry, geometry(assigns.plotted))
      # The plot's coordinate space has to reach the template as assigns: inside
      # ~H, `@width` resolves against assigns, not module attributes.
      |> assign(:width, @width)
      |> assign(:height, @height)
      |> assign(:readout, readout(assigns.plotted))
      |> assign(:flow_marks, flow_marks(assigns.plotted))
      |> assign(:range_counts, range_counts(assigns.series))
      |> assign(:flat?, flat?(windowed))
      # One test for "is there a line", so the plot, its axis labels and the
      # not-enough-data notice can never disagree about whether one exists.
      |> assign(:drawable?, match?([_, _ | _], windowed))

    ~H"""
    <section class="space-y-2" id="portfolio-chart">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <p class="font-bold uppercase tracking-widest">Gain / loss · {range_label(@range)}</p>
        <span class={["ic-stat-n text-xl", hero_class(@points)]}>{hero(@points)}</span>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex gap-1" role="tablist" aria-label="Time range">
          <button
            :for={{name, _days} <- ranges()}
            type="button"
            role="tab"
            aria-selected={@range == name}
            phx-click="trading_select_range"
            phx-value-range={name}
            title={
              if Map.get(@range_counts, name, 0) < 2,
                do: "Not enough readings yet to draw a line for this range",
                else: nil
            }
            class={[
              "border-2 px-2 py-0.5 font-bold uppercase tracking-wide transition",
              if(@range == name,
                do: "border-primary bg-primary/10",
                else: "border-base-content/25 hover:bg-base-content/5"
              ),
              Map.get(@range_counts, name, 0) < 2 && "opacity-40"
            ]}
          >
            {name}
          </button>
        </div>
        <%!-- Downsampling is disclosed, never silent: a monthly line and a daily
              line look identical, and the reader deserves to know which. --%>
        <span class="text-base-content/50">{granularity_label(@granularity, @plotted)}</span>
      </div>

      <p :if={@points == []} class="border-2 border-base-content/20 p-4 text-base-content/60">
        No history yet for {@label}. Readings are taken once per trading day —
        the line begins as soon as there are two.
      </p>

      <%!-- One reading cannot be a line. Saying so beats rendering an axis with
            a lone dot on it, which reads as a chart that failed to draw. --%>
      <p :if={match?([_], @points)} class="border-2 border-base-content/20 p-4 text-base-content/60">
        Only one reading in {range_phrase(@range)} — a line needs two. Readings are taken
        once per trading day, so this fills in tomorrow. A longer range will show
        the history that already exists.
      </p>

      <%!-- A flat window is a real answer, but it draws the line exactly on top
            of the zero baseline, where it reads as nothing having rendered. So
            the result gets said in words as well as drawn. --%>
      <p :if={@flat? and @drawable?} class="text-base-content/60">
        No change over {range_phrase(@range)} — the line sits on zero because nothing
        moved, not because it is missing.
      </p>

      <div
        :if={@drawable?}
        class="relative"
        id="portfolio-chart-plot"
        phx-hook="PortfolioChart"
        phx-update="ignore"
        data-readout={@readout}
      >
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          preserveAspectRatio="none"
          class="h-48 w-full cursor-crosshair focus:outline-2 focus:outline-primary"
          tabindex="0"
          role="img"
          aria-label={"Cumulative gain and loss for #{@label}: #{hero(@points)}. Use arrow keys to read individual points."}
        >
          <%!-- Zero baseline. Recessive, but always present. --%>
          <line
            x1="0"
            y1={@geometry.zero_y}
            x2={@width}
            y2={@geometry.zero_y}
            stroke="currentColor"
            stroke-width="1"
            stroke-dasharray="4 4"
            class="text-base-content/30"
          />

          <path
            :for={segment <- @segments}
            d={segment.d}
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-dasharray={if segment.measure == :realized, do: "6 4"}
            vector-effect="non-scaling-stroke"
            class={segment_class(segment.measure, @points)}
          />

          <%!-- Transfer marks. A deposit is netted OUT of the gain by design,
                so it leaves no trace in the line — which means a reader has no
                way to check the arithmetic unless the day is marked. --%>
          <line
            :for={mark <- @flow_marks}
            x1={mark.x}
            y1="0"
            x2={mark.x}
            y2={@height}
            stroke="currentColor"
            stroke-width="1"
            stroke-dasharray="2 3"
            vector-effect="non-scaling-stroke"
            class="text-warning/60"
          />

          <line
            data-crosshair
            x1="0"
            y1="0"
            x2="0"
            y2={@height}
            stroke="currentColor"
            stroke-width="1"
            vector-effect="non-scaling-stroke"
            class="text-base-content/40"
            style="display: none"
          />

          <circle
            data-crosshair-dot
            r="4"
            fill="currentColor"
            vector-effect="non-scaling-stroke"
            class={segment_class(:recorded, @points)}
            style="display: none"
          />

          <circle
            :for={dot <- @geometry.dots}
            cx={dot.x}
            cy={dot.y}
            r="3"
            fill="currentColor"
            vector-effect="non-scaling-stroke"
            class={segment_class(dot.measure, @points)}
          />
        </svg>

        <%!-- Axis labels in HTML: the viewBox stretches, and text inside it
              would stretch with the plot. --%>
        <div class="pointer-events-none absolute inset-0 flex flex-col justify-between text-base-content/50">
          <span>{money(@geometry.max_cents)}</span>
          <span>{money(@geometry.min_cents)}</span>
        </div>

        <div
          data-tooltip
          class="pointer-events-none absolute z-10 hidden max-w-[16rem] border-2 border-base-content/40 bg-base-100 px-2 py-1 shadow-lg"
        >
        </div>

        <%!-- The screen-reader path. Hover and keyboard produce the same
              sentence; without this the chart is mouse-only in practice. --%>
        <p data-live class="sr-only" aria-live="polite"></p>
      </div>

      <div :if={length(@points) > 1} class="flex flex-wrap justify-between gap-2 text-base-content/50">
        <span>{first_day(@points)}</span>
        <span>{last_day(@points)}</span>
      </div>

      <%!-- The seam caption. The line changes meaning partway along, and no
            amount of styling substitutes for saying so in words. --%>
      <p :if={has_realized?(@points)} class="text-base-content/60">
        <span class="font-bold">╌╌</span>
        realized trades only, before recording began · <span class="font-bold">──</span>
        realized + unrealized, recorded here
      </p>

      <div :if={@points != []}>
        <button
          type="button"
          phx-click="trading_toggle_table"
          aria-expanded={@table}
          class="border-2 border-base-content/30 px-2 py-0.5 uppercase tracking-wide transition hover:bg-base-content/10"
        >
          {if @table, do: "Hide table", else: "Show table"}
        </button>
      </div>

      <%!-- The table is the accessible equivalent AND the thing you copy numbers
            out of. It lists exactly the plotted points, so it can never disagree
            with the line above it. --%>
      <div
        :if={@table and @points != []}
        class="max-h-64 overflow-auto border-2 border-base-content/20"
      >
        <table class="w-full text-left">
          <thead class="sticky top-0 bg-base-100">
            <tr class="border-b-2 border-base-content/20">
              <th scope="col" class="px-2 py-1">Date</th>
              <th scope="col" class="px-2 py-1 text-right">Change</th>
              <th scope="col" class="px-2 py-1 text-right">Cumulative</th>
              <th scope="col" class="px-2 py-1 text-right">Value</th>
              <th scope="col" class="px-2 py-1">Source</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- Enum.reverse(@plotted)} class="border-b border-base-content/10">
              <td class="px-2 py-1">{Date.to_iso8601(p.day)}</td>
              <td class="px-2 py-1 text-right">{signed_money(p.gain_cents)}</td>
              <td class="px-2 py-1 text-right">{signed_money(p.cumulative_cents)}</td>
              <td class="px-2 py-1 text-right">{money(p.value_cents)}</td>
              <td class="px-2 py-1 text-base-content/60">
                {if p.measure == :realized, do: "realized", else: "recorded"}<span
                  :if={Map.get(p, :flow_cents, 0) != 0}
                  class="text-warning"
                >
                  · transfer {signed_money(p.flow_cents)}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Exclusions. A total that quietly drops an account is not a
            simplification, it is a more flattering number — so the line says
            how many it is leaving out, every time it is leaving any out. --%>
      <p :if={@coverage && Map.get(@coverage, :excluded, []) != []} class="text-base-content/60">
        Excludes {length(@coverage.excluded)} account{if length(@coverage.excluded) == 1,
          do: "",
          else: "s"} you took out of the total.
        Their own charts are unaffected.
      </p>

      <%!-- Coverage. An understated total is a quiet failure, so it gets loud
            text rather than being left to infer from the line's shape. --%>
      <div :if={@coverage && @coverage.missing != []} class="flex flex-wrap items-center gap-2">
        <p class="text-warning">
          History is missing for {length(@coverage.missing)} of {@coverage.accounts} accounts, so
          the earlier stretch is understated.
        </p>
        <button
          type="button"
          phx-click="trading_backfill"
          disabled={@backfilling}
          class="border-2 border-base-content/40 px-2 py-0.5 font-bold uppercase tracking-wide transition hover:bg-base-content/10 disabled:opacity-50"
        >
          {if @backfilling, do: "Loading…", else: "Load history"}
        </button>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Pure helpers — public so they can be tested without rendering
  # ---------------------------------------------------------------------------

  @doc "Trim a series to the selected range, counting back from its last point."
  def window(series, range) do
    case Enum.find(@ranges, fn {name, _days} -> name == range end) do
      {_name, nil} ->
        series

      {_name, days} ->
        case List.last(series) do
          nil ->
            series

          last ->
            cutoff = Date.add(last.day, -days)
            Enum.filter(series, &(Date.compare(&1.day, cutoff) != :lt))
        end

      nil ->
        series
    end
  end

  @doc """
  The granularity to plot at, chosen from the window's span rather than its
  point count — the span is what determines whether daily marks can be told
  apart.
  """
  def granularity([]), do: :daily
  def granularity([_single]), do: :daily

  def granularity(points) do
    span = Date.diff(List.last(points).day, List.first(points).day)

    cond do
      span <= 45 -> :daily
      span <= 400 -> :weekly
      true -> :monthly
    end
  end

  @doc """
  Reduce a window to one point per period, keeping the **last** point in each.

  Last, not an average: the series is a running level, so the closing value of a
  period is a real reading that actually occurred, while a mean of levels is a
  number that never existed. Measures are downsampled separately so the seam
  stays crisp.
  """
  def downsample(points) do
    case granularity(points) do
      :daily ->
        points

      period ->
        points
        |> Enum.group_by(&{&1.measure, period_key(&1.day, period)})
        |> Enum.map(fn {_key, group} -> List.last(group) end)
        |> Enum.sort_by(& &1.day, Date)
    end
  end

  defp period_key(day, :weekly), do: {day.year, div(Date.day_of_year(day), 7)}
  defp period_key(day, :monthly), do: {day.year, day.month}

  @doc """
  Split points into drawable path segments, breaking on a change of measure and
  on any gap in the recorded series.

  A break is not decoration. Connecting across a day we never measured draws a
  trend through data that does not exist.
  """
  def segments(points) when length(points) < 2, do: []

  def segments(points) do
    scale = scale_fns(points)

    points
    |> chunk_points()
    |> Enum.reject(&(length(&1) < 2))
    |> Enum.map(fn chunk ->
      %{measure: List.last(chunk).measure, d: path_d(chunk, scale)}
    end)
  end

  # Two reasons to start a new path, and they are NOT the same reason:
  #
  #   * A **gap** — a trading day went unmeasured. The new path starts clean, so
  #     nothing is drawn across the hole.
  #   * A **change of measure** — the seam. Here the line genuinely does
  #     continue; only its meaning narrows. So the new path starts by REPEATING
  #     the previous point, which draws the connecting stroke and lets the style
  #     change without breaking the line.
  #
  # Without that distinction a two-point window straddling the seam renders
  # nothing at all — caught 07-28 running the real 32-point series through the
  # geometry — and the "one continuous line" the seam design promises would be a
  # claim the chart visibly contradicts.
  defp chunk_points([]), do: []

  defp chunk_points([first | rest]) do
    {done, current} =
      Enum.reduce(rest, {[], [first]}, fn point, {done, [prev | _] = current} ->
        cond do
          point.measure == :recorded and prev.measure == :recorded and
              gap?(prev.day, point.day) ->
            {[Enum.reverse(current) | done], [point]}

          point.measure != prev.measure ->
            {[Enum.reverse(current) | done], [point, prev]}

          true ->
            {done, [point | current]}
        end
      end)

    Enum.reverse([Enum.reverse(current) | done])
  end

  @doc "True when a trading day passed between two readings without being recorded."
  def gap?(from, to) do
    from
    |> Date.range(to)
    |> Enum.drop(1)
    |> Enum.drop(-1)
    |> Enum.any?(&MarketCalendar.trading_day?/1)
  end

  @doc "Plot coordinates and the y-domain, with zero always inside it."
  def geometry([]), do: %{zero_y: @height / 2, dots: [], min_cents: 0, max_cents: 0}

  def geometry(points) do
    scale = scale_fns(points)
    {min_cents, max_cents} = domain(points)

    dots =
      if length(points) <= @max_dots do
        Enum.map(points, fn point ->
          %{x: scale.x.(point.day), y: scale.y.(point.cumulative_cents), measure: point.measure}
        end)
      else
        []
      end

    %{zero_y: scale.y.(0), dots: dots, min_cents: min_cents, max_cents: max_cents}
  end

  defp scale_fns(points) do
    first = List.first(points).day
    span = max(Date.diff(List.last(points).day, first), 0)
    {min_cents, max_cents} = domain(points)
    spread = max(max_cents - min_cents, 1)

    %{
      x: fn day ->
        if span == 0, do: @width / 2, else: Date.diff(day, first) / span * @width
      end,
      y: fn cents ->
        usable = @height - 2 * @pad
        @height - @pad - (cents - min_cents) / spread * usable
      end
    }
  end

  # Zero is forced into the domain: a gain chart that crops the baseline makes a
  # small loss look like a collapse.
  defp domain(points) do
    values = Enum.map(points, & &1.cumulative_cents)
    {Enum.min([0 | values]), Enum.max([0 | values])}
  end

  defp path_d(points, scale) do
    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {point, index} ->
      x = Float.round(scale.x.(point.day) * 1.0, 2)
      y = Float.round(scale.y.(point.cumulative_cents) * 1.0, 2)
      command = if index == 0, do: "M", else: "L"
      "#{command} #{x},#{y}"
    end)
  end

  @doc """
  Re-zero a window so the line measures change *across the readings shown*.

  Without this the line always read cumulative-since-inception, so selecting
  "1M" still showed a figure accumulated over two and a half years — dominated,
  in the operator's own data, by an account that now holds $0 and did its
  trading in early 2025. Both numbers were true; together they were unreadable,
  and the range control looked broken (reported 07-28).

  The baseline is the **first visible point**, not the last one before the
  window. That distinction only bites while the data is sparse, and then it
  bites hard: with monthly backfill buckets and a single recorded day, measuring
  from the previous point credited sixteen months of recovery to "past month".
  Measuring across what is actually on screen cannot do that. Once daily
  recording accumulates the two converge, because the previous point is
  yesterday.

  "ALL" is left alone — nothing precedes it, and its first point already steps
  from an implicit zero, so re-zeroing would erase that first bucket's result.
  """
  def rebase([], _series), do: []

  def rebase([first | _] = windowed, series) do
    baseline = if windowed_from?(series, first.day), do: first.cumulative_cents, else: 0
    Enum.map(windowed, &Map.update!(&1, :cumulative_cents, fn cents -> cents - baseline end))
  end

  # True when the series carries history the window is cutting away.
  defp windowed_from?(series, first_day),
    do: Enum.any?(series, &(Date.compare(&1.day, first_day) == :lt))

  @doc "How many points each range would plot — drives the range buttons' state."
  def range_counts(series) do
    Map.new(@ranges, fn {name, _days} -> {name, series |> window(name) |> length()} end)
  end

  @doc "True when every point in the window carries the same cumulative."
  def flat?([]), do: false
  def flat?(points), do: match?([_], points |> Enum.map(& &1.cumulative_cents) |> Enum.uniq())

  # "the past week" reads correctly; "the all time" does not.
  defp range_phrase("ALL"), do: "all time"
  defp range_phrase(range), do: "the " <> range_label(range)

  defp range_label("ALL"), do: "all time"
  defp range_label("1W"), do: "past week"
  defp range_label("1M"), do: "past month"
  defp range_label("3M"), do: "past 3 months"
  defp range_label("1Y"), do: "past year"
  defp range_label(other), do: other

  @doc """
  The per-point payload the hover/keyboard hook reads, as JSON on a data
  attribute.\"""

  Sent as data rather than re-queried per mousemove: a crosshair that round-trips
  to the server for every pixel of pointer movement is a crosshair that lags.
  """
  def readout([]), do: "[]"

  def readout(points) do
    scale = scale_fns(points)

    points
    |> Enum.map(fn point ->
      %{
        x: Float.round(scale.x.(point.day) * 1.0, 2),
        y: Float.round(scale.y.(point.cumulative_cents) * 1.0, 2),
        label: point_label(point)
      }
    end)
    |> Jason.encode!()
  end

  # One sentence per point, built server-side so the hover text, the keyboard
  # readout, and the screen-reader announcement can never drift apart.
  defp point_label(point) do
    [
      Date.to_iso8601(point.day),
      "#{signed_money(point.cumulative_cents)} cumulative",
      point.gain_cents && "#{signed_money(point.gain_cents)} that #{period_word(point)}",
      point.value_cents && "value #{money(point.value_cents)}",
      flow_phrase(point),
      point.measure == :realized && "realized trades only"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp period_word(%{measure: :realized}), do: "bucket"
  defp period_word(_point), do: "day"

  defp flow_phrase(point) do
    case Map.get(point, :flow_cents, 0) do
      0 -> nil
      cents -> "includes a #{signed_money(cents)} transfer"
    end
  end

  @doc "Plot x-positions of days carrying a transfer, for the chart's marks."
  def flow_marks([]), do: []

  def flow_marks(points) do
    scale = scale_fns(points)

    points
    |> Enum.filter(&(Map.get(&1, :flow_cents, 0) != 0))
    |> Enum.map(&%{x: Float.round(scale.x.(&1.day) * 1.0, 2)})
  end

  # ---------------------------------------------------------------------------
  # Display
  # ---------------------------------------------------------------------------

  defp hero([]), do: "—"

  defp hero(points) do
    points |> List.last() |> Map.fetch!(:cumulative_cents) |> signed_money()
  end

  defp hero_class([]), do: "text-base-content/60"

  defp hero_class(points) do
    if List.last(points).cumulative_cents < 0, do: "text-error", else: "text-success"
  end

  # The recorded line carries the gain/loss color; the realized stretch stays
  # muted because it measures something narrower and should not read as equally
  # complete. Sign is written in the hero number, never color-alone.
  defp segment_class(:realized, _points), do: "text-base-content/40"

  defp segment_class(:recorded, points) do
    if hero_class(points) == "text-error", do: "text-error", else: "text-success"
  end

  defp has_realized?(points), do: Enum.any?(points, &(&1.measure == :realized))

  defp granularity_label(granularity, plotted) do
    unit =
      case granularity do
        :daily -> "daily"
        :weekly -> "weekly"
        :monthly -> "monthly"
      end

    "#{unit} · #{length(plotted)} points"
  end

  defp first_day([]), do: ""
  defp first_day(points), do: points |> List.first() |> Map.fetch!(:day) |> Date.to_iso8601()

  defp last_day([]), do: ""
  defp last_day(points), do: points |> List.last() |> Map.fetch!(:day) |> Date.to_iso8601()

  defp money(cents) when is_integer(cents),
    do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp money(_cents), do: "—"

  defp signed_money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: "+"
    sign <> money(abs(cents))
  end

  defp signed_money(_cents), do: "—"
end
