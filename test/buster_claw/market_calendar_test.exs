defmodule BusterClaw.MarketCalendarTest do
  use ExUnit.Case, async: true

  alias BusterClaw.MarketCalendar

  defp d(iso), do: Date.from_iso8601!(iso)

  describe "holidays/1" do
    test "2025 matches the published NYSE calendar" do
      assert MarketCalendar.holidays(2025) == [
               d("2025-01-01"),
               d("2025-01-20"),
               d("2025-02-17"),
               d("2025-04-18"),
               d("2025-05-26"),
               d("2025-06-19"),
               d("2025-07-04"),
               d("2025-09-01"),
               d("2025-11-27"),
               d("2025-12-25")
             ]
    end

    test "2026 matches, including a Saturday July 4 observed on the Friday" do
      holidays = MarketCalendar.holidays(2026)

      assert d("2026-07-03") in holidays
      refute d("2026-07-04") in holidays
      assert d("2026-04-03") in holidays
      assert d("2026-11-26") in holidays
    end

    test "a Sunday holiday is observed on the following Monday" do
      # July 4, 2027 is a Sunday.
      assert Date.day_of_week(d("2027-07-04")) == 7
      assert d("2027-07-05") in MarketCalendar.holidays(2027)
    end

    test "a Saturday Christmas is observed on the preceding Friday" do
      # December 25, 2027 is a Saturday.
      assert Date.day_of_week(d("2027-12-25")) == 6
      assert d("2027-12-24") in MarketCalendar.holidays(2027)
    end

    test "New Year's on a Saturday does NOT close the preceding December 31" do
      # January 1, 2028 is a Saturday. The exchange's one exception to the
      # observed-on-Friday rule.
      assert Date.day_of_week(d("2028-01-01")) == 6
      refute d("2027-12-31") in MarketCalendar.holidays(2027)
      refute d("2027-12-31") in MarketCalendar.holidays(2028)
      assert MarketCalendar.trading_day?(d("2027-12-31"))
    end

    test "Good Friday tracks Easter across years" do
      # Easter: 2025-04-20, 2026-04-05, 2027-03-28.
      assert d("2025-04-18") in MarketCalendar.holidays(2025)
      assert d("2026-04-03") in MarketCalendar.holidays(2026)
      assert d("2027-03-26") in MarketCalendar.holidays(2027)
    end

    test "every holiday returned is itself a weekday" do
      for year <- 2024..2030, holiday <- MarketCalendar.holidays(year) do
        assert Date.day_of_week(holiday) <= 5,
               "#{holiday} is a weekend day and should not be an observed holiday"
      end
    end

    test "memoization returns an equal list on repeat calls" do
      assert MarketCalendar.holidays(2026) == MarketCalendar.holidays(2026)
    end
  end

  describe "trading_day?/1" do
    test "weekends never trade" do
      # 2026-07-25 is a Saturday, 07-26 a Sunday.
      refute MarketCalendar.trading_day?(d("2026-07-25"))
      refute MarketCalendar.trading_day?(d("2026-07-26"))
      assert MarketCalendar.trading_day?(d("2026-07-27"))
    end

    test "an observed holiday does not trade, and the real date does when shifted" do
      refute MarketCalendar.trading_day?(d("2026-07-03"))
      # July 4 2026 is a Saturday — already not a trading day for that reason.
      refute MarketCalendar.trading_day?(d("2026-07-04"))
      assert MarketCalendar.trading_day?(d("2026-07-06"))
    end

    test "Thanksgiving Friday still trades (a half day is an open day)" do
      assert MarketCalendar.trading_day?(d("2026-11-27"))
    end
  end

  describe "today/0" do
    test "honors the :local_today test seam" do
      prev = Application.get_env(:buster_claw, :local_today)
      Application.put_env(:buster_claw, :local_today, d("2026-01-01"))
      on_exit(fn -> Application.put_env(:buster_claw, :local_today, prev) end)

      assert MarketCalendar.today() == d("2026-01-01")
    end
  end

  describe "now/0" do
    test "resolves Eastern with a real offset, not UTC" do
      # Guards the reason tzdata was added: if the tz database is missing this
      # silently returns UTC and every evening reading is misfiled.
      now = MarketCalendar.now()
      assert now.time_zone == "America/New_York"
      assert now.zone_abbr in ["EST", "EDT"]
      assert now.utc_offset == -18_000
    end
  end
end
