defmodule BusterClaw.Portfolio do
  @moduledoc """
  The portfolio ledger (PORTFOLIO_HISTORY_ROADMAP Phase 0) — our own daily record
  of what each account was worth.

  Robinhood exposes no portfolio-value history (full tool surface probed
  07-27), so this table is the only place that past ever exists. That asymmetry
  drives the whole design: a day we fail to record is gone for good, while a day
  we record *wrongly* deforms the chart for as long as the row survives. The
  ledger therefore prefers a gap to a guess, everywhere.

  ## Writing

  `record/2` takes a stage-1 snapshot (`BusterClaw.Trading`) and upserts one row
  per account for today's market day. It is idempotent: opening the Trading tab
  six times in an afternoon leaves one row per account, the last one winning.

  Two gates stand between a model-sourced float and a permanent row:

    1. **Cents conversion**, done once, here. Floats never reach the database —
       a float ledger accumulates rounding drift that the chart would draw as
       movement nobody made.
    2. **The order-of-magnitude gate.** A reading is refused when it is more than
       `@max_fold` times the previous one (or that small a fraction) *and* moves
       at least `@gate_floor_cents`. The stage-1 pipeline runs through a language
       model reading a tool result and fails roughly one run in six; a wrong
       number that persists is worse than a missing day, because only one of
       those is recoverable. Both conditions are required because a fold test
       alone rejects ordinary deposits into small accounts — see the comment on
       `@gate_floor_cents`.

  ## Which day is "today"

  The **market** day in America/New_York (`MarketCalendar.today/0`), matching
  `get_realized_pnl`'s bucket boundary — not the machine's local date, which on
  a Pacific machine names tomorrow between 9pm and midnight and would file an
  evening reading under the wrong market day. Settled in Phase 1 by adding
  `tzdata`.

  ## Reading

  `series/1` returns per-account daily readings. The combined total is derived by
  `total_series/1` under one rule worth stating plainly:

  > A total point exists for a day only if **every** account known on that day has
  > a reading. A partial total is a fake crash — three accounts recorded and one
  > missed renders as a cliff exactly the size of the account that went missing.

  Days that fail that test are simply absent from the series. Callers draw the
  absence as a gap; nothing interpolates.
  """
  import Ecto.Query

  require Logger

  alias BusterClaw.MarketCalendar
  alias BusterClaw.Portfolio.Flow
  alias BusterClaw.Portfolio.RealizedPoint
  alias BusterClaw.Portfolio.Snapshot
  alias BusterClaw.Repo
  alias BusterClaw.Settings
  alias BusterClaw.Trading

  # A reading may not differ from the account's previous reading by more than
  # this factor in either direction. Deliberately loose: it is a garbage filter,
  # not a volatility opinion. A real account can double in a day; it cannot
  # credibly go up fifty-fold.
  @max_fold 50

  # ...but the fold test alone is wrong on small balances, and wrong in the
  # direction that costs real data. Funding a $3 account with $500 is a 149x
  # jump and a completely ordinary thing to do; rejecting it loses a real day
  # AND suppresses the transfer prompt that would have explained it (found
  # 07-27, building Phase 2). So a reading is refused only when it fails the
  # fold test *and* moves real money — which is what model garbage actually
  # looks like: a units error ($102 -> $10,200) or a hallucinated magnitude.
  @gate_floor_cents 500_000

  @doc """
  Record every account in a stage-1 snapshot for today's market day.

  Returns `{:ok, count}` with the number of rows written, or `{:error, reason}`
  if the snapshot has no usable accounts. Individual accounts that fail their
  gate are skipped and logged — one bad account must not cost the others their
  reading.
  """
  def record(snapshot, opts \\ []) do
    day = Keyword.get(opts, :day, MarketCalendar.today())
    source = Keyword.get(opts, :source, "tab_open")

    case Trading.accounts(snapshot) do
      [] ->
        {:error, :no_accounts}

      accounts ->
        written =
          accounts
          |> Enum.map(&record_account(&1, day, source))
          |> Enum.count(&match?({:ok, _}, &1))

        {:ok, written}
    end
  end

  defp record_account(account, day, source) do
    with {:ok, key} <- account_key(account),
         {:ok, value_cents} <- to_cents(account["value"]),
         :ok <- within_tolerance(key, value_cents, day) do
      %Snapshot{}
      |> Snapshot.changeset(%{
        account_key: key,
        label: account["label"] || "Account",
        captured_on: day,
        value_cents: value_cents,
        cash_cents: optional_cents(account["cash"]),
        buying_power_cents: optional_cents(account["buying_power"]),
        source: source
      })
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:label, :value_cents, :cash_cents, :buying_power_cents, :source, :updated_at]},
        conflict_target: [:account_key, :captured_on]
      )
      |> case do
        {:ok, _row} = ok ->
          ok

        {:error, changeset} ->
          Logger.warning("Portfolio: refusing #{key} for #{day}: #{inspect(changeset.errors)}")
          {:error, :invalid}
      end
    else
      {:error, reason} ->
        Logger.warning("Portfolio: skipping an account for #{day}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The ledger keys on last4, the same value stage 2 matches accounts on. An
  # account without one cannot be tracked across days — its rows would detach
  # from every earlier reading — so it is skipped rather than filed under a key
  # that will not match tomorrow.
  defp account_key(account) do
    case Trading.last4(account) do
      nil -> {:error, :unidentifiable_account}
      key -> {:ok, key}
    end
  end

  @doc """
  Convert a dollar amount to integer cents, rounding exactly once.

  Accepts floats and integers (what the model returns) and refuses anything
  else, including negatives — a negative account value would invert every gain
  computed after it.
  """
  def to_cents(dollars) when is_number(dollars) and dollars >= 0,
    do: {:ok, round(dollars * 100)}

  def to_cents(dollars) when is_number(dollars), do: {:error, {:negative_value, dollars}}
  def to_cents(other), do: {:error, {:non_numeric_value, other}}

  # Cash and buying power are nullable: unlike value they aren't load-bearing for
  # the chart, so a bad one costs the field, not the row.
  defp optional_cents(dollars) do
    case to_cents(dollars) do
      {:ok, cents} -> cents
      {:error, _reason} -> nil
    end
  end

  # The order-of-magnitude gate. Compares against the most recent reading BEFORE
  # this day, so re-recording the same day (the idempotent path) is never gated
  # against its own earlier value.
  defp within_tolerance(key, value_cents, day) do
    case previous_value_cents(key, day) do
      nil ->
        :ok

      0 ->
        :ok

      prev ->
        big_move? = abs(value_cents - prev) >= @gate_floor_cents

        cond do
          not big_move? -> :ok
          value_cents > prev * @max_fold -> {:error, {:implausible_jump, prev, value_cents}}
          value_cents * @max_fold < prev -> {:error, {:implausible_drop, prev, value_cents}}
          true -> :ok
        end
    end
  end

  defp previous_value_cents(key, day) do
    Snapshot
    |> where([s], s.account_key == ^key and s.captured_on < ^day)
    |> order_by([s], desc: s.captured_on)
    |> limit(1)
    |> select([s], s.value_cents)
    |> Repo.one()
  end

  @doc "True when any account already has a reading for `day`."
  def recorded_on?(%Date{} = day) do
    Snapshot
    |> where([s], s.captured_on == ^day)
    |> limit(1)
    |> Repo.aggregate(:count)
    |> Kernel.>(0)
  end

  @doc "Every reading for one account, oldest first."
  def series(account_key) when is_binary(account_key) do
    Snapshot
    |> where([s], s.account_key == ^account_key)
    |> order_by([s], asc: s.captured_on)
    |> Repo.all()
  end

  @doc "Every reading, oldest first, across all accounts."
  def all_snapshots do
    Snapshot
    |> order_by([s], asc: s.captured_on, asc: s.account_key)
    |> Repo.all()
  end

  @doc """
  The combined total per day, oldest first, as `[%{day: Date.t(), value_cents:
  integer, accounts: integer}]`.

  Only days where every account known *as of that day* reported are included. An
  account is "known" from its first-ever reading onward, so adding a new account
  today does not retroactively invalidate a year of complete history.
  """
  def total_series do
    excluded = excluded_accounts()
    snapshots = Enum.reject(all_snapshots(), &(&1.account_key in excluded))
    first_seen = first_seen_by_account(snapshots)

    snapshots
    |> Enum.group_by(& &1.captured_on)
    |> Enum.sort_by(fn {day, _rows} -> day end, Date)
    |> Enum.flat_map(fn {day, rows} ->
      expected =
        Enum.count(first_seen, fn {_key, seen_on} -> Date.compare(seen_on, day) != :gt end)

      if length(rows) == expected and expected > 0 do
        [
          %{
            day: day,
            value_cents: Enum.sum(Enum.map(rows, & &1.value_cents)),
            accounts: expected,
            # The opening balance of any account reporting for the FIRST time
            # today. An account joining the tracked set moves money into that
            # set exactly the way a deposit moves money into an account, and
            # counting it as gain would credit the user with $900 of
            # performance for opening an account (caught 07-28 via the command
            # surface's own test). `total_gain_series/0` subtracts it.
            entering_cents:
              rows
              |> Enum.filter(&(Map.get(first_seen, &1.account_key) == day))
              |> Enum.map(& &1.value_cents)
              |> Enum.sum()
          }
        ]
      else
        # An incomplete day is a gap, not a smaller total. Drawing the sum of
        # whatever happened to report would render a crash the size of the
        # missing account.
        []
      end
    end)
  end

  defp first_seen_by_account(snapshots) do
    Enum.reduce(snapshots, %{}, fn snap, acc ->
      Map.update(acc, snap.account_key, snap.captured_on, fn seen ->
        if Date.compare(snap.captured_on, seen) == :lt, do: snap.captured_on, else: seen
      end)
    end)
  end

  @doc "Dollars for display, from integer cents."
  def to_dollars(cents) when is_integer(cents), do: cents / 100
  def to_dollars(_cents), do: nil

  # ---------------------------------------------------------------------------
  # Excluded accounts
  # ---------------------------------------------------------------------------

  @excluded_key "portfolio_excluded_accounts"

  @doc """
  Account keys the operator has taken out of the combined total.

  Excluding is a *presentation* choice about the total, never a deletion: the
  account keeps every reading, keeps its own chart, and can be brought back with
  one click. It exists because a dormant account can dominate a combined figure
  — a $0 balance carrying a −$715 realized history swamped the operator's two
  live accounts (07-28).

  Which is also why every surface that applies this must SAY it is applying it.
  A total that quietly drops a losing account is not a simplification, it is a
  more flattering number, and the whole ledger is built on not producing those.
  """
  def excluded_accounts do
    case Settings.get(@excluded_key) do
      raw when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, keys} when is_list(keys) -> Enum.filter(keys, &is_binary/1)
          _other -> []
        end

      _other ->
        []
    end
  end

  @doc "Take an account out of the combined total."
  def exclude_account(key) when is_binary(key) do
    put_excluded(Enum.uniq([key | excluded_accounts()]))
  end

  @doc "Put an account back into the combined total."
  def include_account(key) when is_binary(key) do
    put_excluded(excluded_accounts() -- [key])
  end

  @doc "True when the account is currently out of the total."
  def excluded?(key) when is_binary(key), do: key in excluded_accounts()

  defp put_excluded(keys) do
    Settings.put(@excluded_key, Jason.encode!(keys))
    {:ok, keys}
  end

  # ---------------------------------------------------------------------------
  # Flows (Phase 2)
  # ---------------------------------------------------------------------------

  @doc """
  Record a deposit, a withdrawal, or a day reviewed and found to be neither.

  Replaces any existing flow for that account and day — a day has one answer,
  and re-answering it should correct the record rather than stack a second row
  the gain math would double-count.
  """
  def put_flow(attrs) do
    attrs = normalize_flow_attrs(attrs)

    Repo.transaction(fn ->
      with %{account_key: key, occurred_on: day} when is_binary(key) and not is_nil(day) <- attrs do
        Flow
        |> where([f], f.account_key == ^key and f.occurred_on == ^day)
        |> Repo.delete_all()
      end

      %Flow{}
      |> Flow.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, flow} -> flow
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp normalize_flow_attrs(attrs) do
    Map.new(attrs, fn {k, v} -> {if(is_binary(k), do: String.to_existing_atom(k), else: k), v} end)
  end

  @doc "Every flow for an account, oldest first."
  def flows(account_key) when is_binary(account_key) do
    Flow
    |> where([f], f.account_key == ^account_key)
    |> order_by([f], asc: f.occurred_on)
    |> Repo.all()
  end

  @doc "Every flow across all accounts, oldest first."
  def all_flows do
    Flow
    |> order_by([f], asc: f.occurred_on, asc: f.account_key)
    |> Repo.all()
  end

  @doc "Delete an account's flow for a day, returning it to unaccounted-for."
  def delete_flow(account_key, %Date{} = day) when is_binary(account_key) do
    {count, _} =
      Flow
      |> where([f], f.account_key == ^account_key and f.occurred_on == ^day)
      |> Repo.delete_all()

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Gain (Phase 2)
  # ---------------------------------------------------------------------------

  @doc """
  The gain/loss series for one account, oldest first, as

      [%{day: Date.t(), value_cents: integer, gain_cents: integer | nil,
         flow_cents: integer, cumulative_cents: integer}]

  `gain_cents` is `nil` for the first reading: there is no earlier value to
  measure against, and a first point of "zero gain" would be a claim we can't
  support. Cumulative starts at zero there and folds forward.

  Gain is computed **around** flows:

      gain[d] = value[d] − value[prev] − Σ flows in (prev, d]

  The window is open at `prev` and closed at `d` because a flow dated `d` is
  assumed to be reflected in `d`'s reading. It spans from the *previous
  recorded* day, not the previous calendar day, so a flow landing inside a
  recording gap is still subtracted exactly once.
  """
  def gain_series(account_key) when is_binary(account_key) do
    account_key
    |> series()
    |> Enum.map(&%{day: &1.captured_on, value_cents: &1.value_cents})
    |> build_gain_series(flows_by_day(flows(account_key)))
  end

  @doc """
  The gain/loss series for the combined total, oldest first — same shape as
  `gain_series/1`.

  Built on `total_series/0`, so it inherits the completeness rule: days where an
  account failed to report are absent, and a gain spanning that gap measures
  from the last complete day to the next one.
  """
  def total_gain_series do
    points = total_series()

    # Accounts entering the tracked set are folded in with the hand-marked
    # transfers, because they are the same kind of event: money crossing the
    # boundary of what we measure, not money earned inside it.
    entering =
      points
      |> Enum.reject(&(&1.day == points |> List.first() |> then(fn p -> p && p.day end)))
      |> Map.new(&{&1.day, &1.entering_cents})

    flows =
      all_flows()
      |> flows_by_day()
      |> Map.merge(entering, fn _day, flow, entering -> flow + entering end)

    points
    |> Enum.map(&%{day: &1.day, value_cents: &1.value_cents})
    |> build_gain_series(flows)
  end

  defp flows_by_day(flows) do
    Enum.reduce(flows, %{}, fn flow, acc ->
      Map.update(acc, flow.occurred_on, flow.amount_cents, &(&1 + flow.amount_cents))
    end)
  end

  defp build_gain_series([], _flows), do: []

  defp build_gain_series([first | rest], flows) do
    initial = %{
      day: first.day,
      value_cents: first.value_cents,
      gain_cents: nil,
      flow_cents: Map.get(flows, first.day, 0),
      cumulative_cents: 0
    }

    {points, _} =
      Enum.map_reduce(rest, initial, fn point, prev ->
        flow_cents = flow_between(flows, prev.day, point.day)
        gain = point.value_cents - prev.value_cents - flow_cents

        current = %{
          day: point.day,
          value_cents: point.value_cents,
          gain_cents: gain,
          flow_cents: flow_cents,
          cumulative_cents: prev.cumulative_cents + gain
        }

        {current, current}
      end)

    [initial | points]
  end

  # Flows in (prev, day] — see gain_series/1 for why the window is half-open.
  defp flow_between(flows, prev_day, day) do
    flows
    |> Enum.filter(fn {flow_day, _cents} ->
      Date.compare(flow_day, prev_day) == :gt and Date.compare(flow_day, day) != :gt
    end)
    |> Enum.map(fn {_day, cents} -> cents end)
    |> Enum.sum()
  end

  # ---------------------------------------------------------------------------
  # Anomalies (Phase 2)
  # ---------------------------------------------------------------------------

  @doc """
  Days whose value moved enough to look like a transfer and that haven't been
  accounted for yet — the input to the panel's "was that a transfer?" prompt.

  A day is flagged when its raw change is at least `@anomaly_ratio` of the
  previous value **and** at least `@anomaly_floor_cents` in absolute terms. The
  floor exists because a percentage alone would flag every ordinary wobble in a
  small account.

  ## The honest limit

  This catches deposits that are large relative to the account and misses ones
  that aren't. A $1,000 deposit into a $200,000 account is 0.5% and will not be
  flagged — it will sit in the series as gain until someone marks it. That is a
  floor on what detection can do without a transfers API, not a bug, and it is
  why marking a day is available directly and not only via the prompt.
  """
  def anomalies(account_key) when is_binary(account_key) do
    accounted = account_key |> flows() |> MapSet.new(& &1.occurred_on)

    account_key
    |> gain_series()
    |> Enum.filter(fn point ->
      not is_nil(point.gain_cents) and
        not MapSet.member?(accounted, point.day) and
        anomalous?(point)
    end)
  end

  @anomaly_ratio 0.2
  @anomaly_floor_cents 10_000

  defp anomalous?(%{gain_cents: gain, value_cents: value}) do
    magnitude = abs(gain)
    previous = value - gain

    magnitude >= @anomaly_floor_cents and previous > 0 and
      magnitude / previous >= @anomaly_ratio
  end

  @doc """
  The hero row's day change (TRADING_TAB_ROADMAP Phase 2): the combined
  (included) total's two most recent readings, with flows and entering accounts
  netted out — the SAME math as the chart, taken from the same series, because
  the hero number and the line beneath it must not be able to disagree.

  Returns:

    * `:empty` — no complete readings at all
    * `{:single, %{day, value_cents}}` — one reading; there is nothing to
      measure against, and the caller must say so rather than show $0.00
    * `%{day, prev_day, value_cents, change_cents, change_pct, contiguous?}` —
      `contiguous?` is false when a trading day between the two readings went
      unrecorded, in which case this is not "today's change" and the caller
      must label the baseline date instead
  """
  def total_day_change do
    case total_gain_series() |> Enum.take(-2) do
      [] ->
        :empty

      [only] ->
        {:single, %{day: only.day, value_cents: only.value_cents}}

      [prev, last] ->
        prev_trading = MarketCalendar.latest_trading_day(Date.add(last.day, -1))

        %{
          day: last.day,
          prev_day: prev.day,
          value_cents: last.value_cents,
          change_cents: last.gain_cents,
          change_pct: if(prev.value_cents > 0, do: last.gain_cents / prev.value_cents * 100),
          contiguous?: Date.compare(prev.day, prev_trading) != :lt
        }
    end
  end

  @doc "The most recent unaccounted-for anomaly for an account, or nil."
  def latest_anomaly(account_key) when is_binary(account_key) do
    case account_key |> anomalies() |> List.last() do
      nil -> nil
      point -> Map.put(point, :account_key, account_key)
    end
  end

  @doc """
  The most recent unaccounted-for anomaly across several accounts, or nil.

  The combined view has no single account to ask about, and a prompt nobody can
  reach is a prompt that never gets answered — so it asks about whichever
  account moved most recently. The returned point carries its `:account_key`,
  which is what the answer is filed against.
  """
  def latest_anomaly_across(account_keys) when is_list(account_keys) do
    account_keys
    |> Enum.map(&latest_anomaly/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.day, Date, fn -> nil end)
  end

  # ---------------------------------------------------------------------------
  # Backfill (Phase 3)
  # ---------------------------------------------------------------------------

  @doc """
  Fetch and store an account's realized-P&L history, replacing whatever was
  stored before.

  Returns `{:ok, count}` or `{:error, reason}`. Blocking; callers run it under
  `start_async`.
  """
  def backfill(account_key) when is_binary(account_key) do
    case Trading.fetch_realized_pnl(account_key) do
      {:ok, buckets} -> {:ok, store_backfill(account_key, buckets)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Store parsed backfill buckets for an account, replacing any prior set.

  A wholesale replace rather than an upsert: the API owns this history, its
  bucket boundaries can shift between calls, and merging two different
  bucketings of the same months would double-count the overlap.
  """
  def store_backfill(account_key, buckets) when is_binary(account_key) and is_list(buckets) do
    Repo.transaction(fn ->
      RealizedPoint
      |> where([p], p.account_key == ^account_key)
      |> Repo.delete_all()

      Enum.count(buckets, fn bucket ->
        result =
          %RealizedPoint{}
          |> RealizedPoint.changeset(%{
            account_key: account_key,
            bucket_on: bucket.bucket_on,
            realized_cents: to_signed_cents(bucket.realized),
            trades: bucket.trades
          })
          |> Repo.insert()

        match?({:ok, _}, result)
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, _reason} -> 0
    end
  end

  @doc """
  Signed cents, rounded once. Unlike `to_cents/1` this accepts negatives — a
  losing month is a real result — and treats `nil` (the API's "no closing
  trades") as exactly zero realized.
  """
  def to_signed_cents(nil), do: 0
  def to_signed_cents(dollars) when is_number(dollars), do: round(dollars * 100)
  def to_signed_cents(_other), do: 0

  @doc "An account's realized-P&L buckets, oldest first."
  def realized_points(account_key) when is_binary(account_key) do
    RealizedPoint
    |> where([p], p.account_key == ^account_key)
    |> order_by([p], asc: p.bucket_on)
    |> Repo.all()
  end

  @doc "True when an account has any stored backfill."
  def backfilled?(account_key) when is_binary(account_key) do
    RealizedPoint
    |> where([p], p.account_key == ^account_key)
    |> limit(1)
    |> Repo.aggregate(:count)
    |> Kernel.>(0)
  end

  @doc """
  How complete the combined realized segment is:

      %{accounts: integer, backfilled: integer, missing: [account_key]}

  The recorded side refuses to draw a partial total, because a missing account
  renders as a cliff. The realized side can't take that line — one flaky backfill
  would hide years of history for every account — so it degrades differently: the
  total is drawn, and it is **understated** by whatever the missing accounts
  realized.

  That is a quieter failure than a cliff, which is exactly why it needs saying
  out loud. The chart labels it from this; it must not be inferred from the
  shape of the line. (A backfill failing is not hypothetical: the 07-27 run lost
  one account of three to a transient MCP outage.)
  """
  def backfill_coverage do
    excluded = excluded_accounts()

    keys =
      Snapshot
      |> select([s], s.account_key)
      |> distinct(true)
      |> Repo.all()
      |> Enum.reject(&(&1 in excluded))

    missing = Enum.reject(keys, &backfilled?/1)

    %{
      accounts: length(keys),
      backfilled: length(keys) - length(missing),
      missing: missing,
      excluded: excluded
    }
  end

  @doc "Discard an account's backfill, degrading the chart to recorded history."
  def clear_backfill(account_key) when is_binary(account_key) do
    {count, _} =
      RealizedPoint
      |> where([p], p.account_key == ^account_key)
      |> Repo.delete_all()

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # The joined series (Phase 3) — what the chart draws
  # ---------------------------------------------------------------------------

  @doc """
  Cumulative gain/loss for one account, oldest first, spanning both measures:

      [%{day: Date.t(), cumulative_cents: integer, measure: :realized | :recorded,
         gain_cents: integer | nil, value_cents: integer | nil}]

  Before the seam the points are cumulative **realized** P&L from Robinhood —
  closed trades only, monthly, and blind to gains still being held. From the
  seam onward they are cumulative gain computed from our own readings, which
  sees both realized and unrealized.

  The two segments join continuously: the recorded segment starts from the
  backfill's final cumulative rather than from zero, so the line is one line.
  What changes at the seam is **completeness**, not units — which is exactly one
  sentence for the chart to label, and why this is a single axis rather than two.

  ## The seam's known imprecision

  Backfill buckets are monthly. The bucket containing the first recorded day
  straddles the seam, so a little post-seam realized activity sits inside the
  dashed segment. Buckets that *start* on or after the seam are dropped to stop
  it double-counting; the straddling one is kept whole because splitting it
  would mean inventing a within-bucket distribution the API never gave us.
  """
  def cumulative_series(account_key) when is_binary(account_key) do
    recorded = gain_series(account_key)
    join_series(realized_points(account_key), recorded)
  end

  @doc """
  Cumulative gain/loss for the combined total — same shape as
  `cumulative_series/1`.

  The realized segment sums every account's cumulative-as-of-that-date, which is
  a step function: each account holds its last known cumulative between its own
  buckets, so accounts whose months don't align still add up correctly.
  """
  def total_cumulative_series do
    join_series(merged_realized_points(), total_gain_series())
  end

  defp join_series(points, recorded) do
    seam = recorded |> List.first() |> then(&(&1 && &1.day))

    realized =
      points
      |> drop_from_seam(seam)
      |> Enum.scan(0, fn point, running -> running + realized_cents_of(point) end)
      |> Enum.zip(drop_from_seam(points, seam))
      |> Enum.map(fn {cumulative, point} ->
        %{
          day: bucket_day(point),
          cumulative_cents: cumulative,
          measure: :realized,
          gain_cents: realized_cents_of(point),
          value_cents: nil,
          flow_cents: 0
        }
      end)

    offset = realized |> List.last() |> then(&((&1 && &1.cumulative_cents) || 0))

    recorded_points =
      Enum.map(recorded, fn point ->
        %{
          day: point.day,
          cumulative_cents: offset + point.cumulative_cents,
          measure: :recorded,
          gain_cents: point.gain_cents,
          value_cents: point.value_cents,
          # Carried through so the chart can MARK the day. A deposit that was
          # netted out of the gain is invisible in the line by design; a reader
          # who can't see it was there has no way to check the arithmetic.
          flow_cents: Map.get(point, :flow_cents, 0)
        }
      end)

    realized ++ recorded_points
  end

  # Buckets starting on or after the seam belong to the recorded segment's
  # window; keeping them would count the same days twice.
  defp drop_from_seam(points, nil), do: points

  defp drop_from_seam(points, seam),
    do: Enum.filter(points, &(Date.compare(bucket_day(&1), seam) == :lt))

  defp bucket_day(%RealizedPoint{bucket_on: day}), do: day
  defp bucket_day(%{day: day}), do: day

  defp realized_cents_of(%RealizedPoint{realized_cents: cents}), do: cents
  defp realized_cents_of(%{realized_cents: cents}), do: cents

  # Every account's realized history merged onto one timeline. At each date the
  # total is the sum of each account's most recent cumulative — a step function,
  # so accounts with different bucket boundaries still combine correctly.
  defp merged_realized_points do
    excluded = excluded_accounts()

    by_account =
      RealizedPoint
      |> order_by([p], asc: p.bucket_on)
      |> Repo.all()
      |> Enum.reject(&(&1.account_key in excluded))
      |> Enum.group_by(& &1.account_key)

    cumulative_by_account =
      Map.new(by_account, fn {key, points} ->
        {key,
         points
         |> Enum.scan(0, fn point, running -> running + point.realized_cents end)
         |> Enum.zip(points)
         |> Enum.map(fn {cumulative, point} -> {point.bucket_on, cumulative} end)}
      end)

    days =
      cumulative_by_account
      |> Enum.flat_map(fn {_key, pairs} -> Enum.map(pairs, &elem(&1, 0)) end)
      |> Enum.uniq()
      |> Enum.sort(Date)

    {points, _} =
      Enum.map_reduce(days, 0, fn day, previous_total ->
        total =
          Enum.reduce(cumulative_by_account, 0, fn {_key, pairs}, acc ->
            acc + cumulative_as_of(pairs, day)
          end)

        {%{day: day, realized_cents: total - previous_total}, total}
      end)

    points
  end

  defp cumulative_as_of(pairs, day) do
    pairs
    |> Enum.take_while(fn {bucket_on, _cumulative} -> Date.compare(bucket_on, day) != :gt end)
    |> List.last()
    |> then(&((&1 && elem(&1, 1)) || 0))
  end
end
