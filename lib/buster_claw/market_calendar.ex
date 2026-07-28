defmodule BusterClaw.MarketCalendar do
  @moduledoc """
  US equity market days (PORTFOLIO_HISTORY_ROADMAP Phase 1).

  The portfolio ledger records one reading per **trading day**. Weekends and
  exchange holidays get no reading at all — not a duplicate of the prior close.
  A duplicated point isn't false (the account really was worth that), but it
  puts a mark on the chart for a day the market never opened, and a run of them
  reads as a stretch of flat performance rather than a closed exchange.

  ## Which day is "today"

  `today/0` returns the date in **America/New_York**, not the machine's local
  date. On a Pacific machine those disagree between 9pm and midnight, which
  would file an evening reading under the wrong market day. Resolving Eastern
  needs a real IANA database, which is why the project carries `tzdata`.

  ## Holidays

  The NYSE list, computed rather than tabulated so it doesn't expire:
  New Year's Day, MLK Day, Washington's Birthday, Good Friday, Memorial Day,
  Juneteenth, Independence Day, Labor Day, Thanksgiving, Christmas.

  Observance follows the exchange's rule: a holiday on Saturday closes the
  preceding Friday, one on Sunday closes the following Monday — with the
  standard New Year's exception, where a January 1 on Saturday does *not* close
  the preceding December 31.

  Not modeled: half-days (the market opens, so a reading is legitimate) and
  unscheduled closures (hurricanes, national days of mourning). An unscheduled
  closure produces one duplicate-valued point, which is the mild failure, not
  the dangerous one.
  """

  require Logger

  @zone "America/New_York"

  @doc "Today's date in the market's timezone."
  def today do
    case Application.get_env(:buster_claw, :local_today) do
      %Date{} = date -> date
      _other -> now() |> DateTime.to_date()
    end
  end

  @doc """
  The current moment in the market's timezone.

  Falls back to UTC if the tz database is unavailable, but **loudly**. The
  fallback reintroduces the precise bug `tzdata` was added to fix — UTC runs
  ahead of Eastern, so between 8pm and midnight ET it names tomorrow — and a
  silent version of that would quietly misfile readings for as long as it went
  unnoticed. If this warning appears, the tzdata application isn't running.
  """
  def now do
    case DateTime.now(@zone) do
      {:ok, dt} ->
        dt

      error ->
        Logger.warning(
          "MarketCalendar: #{@zone} unresolvable (#{inspect(error)}); falling back to UTC. " <>
            "Market days may be off by one between 8pm and midnight ET."
        )

        DateTime.utc_now()
    end
  end

  @doc "The market timezone name."
  def zone, do: @zone

  @doc """
  True when the exchange is open on `date` — a weekday that isn't an observed
  holiday.
  """
  def trading_day?(%Date{} = date) do
    Date.day_of_week(date) <= 5 and date not in holidays(date.year)
  end

  @doc """
  The most recent trading day on or before `date` — the day whose close is the
  freshest a daily bar can possibly be. Bounded walk (a holiday weekend is the
  longest closure), so termination is structural.
  """
  def latest_trading_day(%Date{} = date) do
    Enum.find(0..10, &trading_day?(Date.add(date, -&1)))
    |> then(&Date.add(date, -&1))
  end

  @doc """
  The observed market holidays for `year`, as a sorted list of dates.

  Memoized per year in `:persistent_term`: the recorder asks on every tick and
  the answer for a given year never changes.
  """
  def holidays(year) when is_integer(year) do
    case :persistent_term.get({__MODULE__, :holidays, year}, nil) do
      nil ->
        computed = compute_holidays(year)
        :persistent_term.put({__MODULE__, :holidays, year}, computed)
        computed

      computed ->
        computed
    end
  end

  defp compute_holidays(year) do
    [
      observed(Date.new!(year, 1, 1), :new_years),
      nth_weekday(year, 1, 1, 3),
      nth_weekday(year, 2, 1, 3),
      good_friday(year),
      last_weekday(year, 5, 1),
      observed(Date.new!(year, 6, 19), :ordinary),
      observed(Date.new!(year, 7, 4), :ordinary),
      nth_weekday(year, 9, 1, 1),
      nth_weekday(year, 11, 4, 4),
      observed(Date.new!(year, 12, 25), :ordinary)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

  # Saturday holidays move to the preceding Friday, Sunday holidays to the
  # following Monday. New Year's is the exception: the exchange does not close
  # on December 31 for a January 1 that lands on a Saturday.
  defp observed(%Date{} = date, kind) do
    case Date.day_of_week(date) do
      6 when kind == :new_years -> nil
      6 -> Date.add(date, -1)
      7 -> Date.add(date, 1)
      _weekday -> date
    end
  end

  # The nth `weekday` (1 = Monday) of a month.
  defp nth_weekday(year, month, weekday, nth) do
    first = Date.new!(year, month, 1)
    offset = rem(weekday - Date.day_of_week(first) + 7, 7)
    Date.add(first, offset + (nth - 1) * 7)
  end

  defp last_weekday(year, month, weekday) do
    last = Date.end_of_month(Date.new!(year, month, 1))
    Date.add(last, -rem(Date.day_of_week(last) - weekday + 7, 7))
  end

  defp good_friday(year), do: Date.add(easter(year), -2)

  # Gregorian Easter, anonymous algorithm. Good Friday is the only market
  # holiday that moves with the lunar calendar, so this is the only place the
  # calendar can't be expressed as "nth weekday of month".
  defp easter(year) do
    a = rem(year, 19)
    b = div(year, 100)
    c = rem(year, 100)
    d = div(b, 4)
    e = rem(b, 4)
    f = div(b + 8, 25)
    g = div(b - f + 1, 3)
    h = rem(19 * a + b - d - g + 15, 30)
    i = div(c, 4)
    k = rem(c, 4)
    l = rem(32 + 2 * e + 2 * i - h - k, 7)
    m = div(a + 11 * h + 22 * l, 451)
    month = div(h + l - 7 * m + 114, 31)
    day = rem(h + l - 7 * m + 114, 31) + 1

    Date.new!(year, month, day)
  end
end
