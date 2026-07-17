defmodule BusterClaw.Wallets do
  @moduledoc """
  Wallets — a transaction ledger for financial management.

  A wallet is either a `business` wallet (cash-flow ledger) or a `personal`
  wallet, which layers monthly budgets (income/expense/savings targets vs.
  actuals) on the same ledger. Every wallet keeps a cached `balance_cents`
  running balance, recomputed whenever a transaction is added or removed.

  Money is represented as integer cents throughout. Changes broadcast on the
  `"wallets"` PubSub topic so LiveViews update in real time across sessions.
  """

  import Ecto.Query

  require Logger

  alias BusterClaw.{Browser, Finance, Library, Repo, Telephony}
  alias BusterClaw.Wallets.{Budget, Feed, Transaction, Wallet}

  @topic "wallets"

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)
  end

  # ---------------------------------------------------------------------------
  # Wallets (canonical CRUD — shape required by the Commands auto-CRUD loop)
  # ---------------------------------------------------------------------------

  def list_wallets do
    Wallet
    |> order_by([w], asc: w.archived, asc: w.name)
    |> Repo.all()
  end

  def get_wallet!(id), do: Repo.get!(Wallet, id)

  def get_wallet(id), do: Repo.get(Wallet, id)

  def create_wallet(attrs) do
    %Wallet{}
    |> Wallet.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change(:created)
  end

  def update_wallet(%Wallet{} = wallet, attrs) do
    wallet
    |> Wallet.changeset(attrs)
    |> Repo.update()
    |> broadcast_change(:updated)
  end

  def delete_wallet(%Wallet{} = wallet) do
    wallet
    |> Repo.delete()
    |> broadcast_change(:deleted)
  end

  def change_wallet(%Wallet{} = wallet \\ %Wallet{}, attrs \\ %{}) do
    Wallet.changeset(wallet, attrs)
  end

  # ---------------------------------------------------------------------------
  # BusterClaw template (running-cost wallet)
  # ---------------------------------------------------------------------------

  @doc "True when this wallet uses the BusterClaw running-cost template."
  def busterclaw?(%Wallet{template: "busterclaw"}), do: true
  def busterclaw?(%Wallet{}), do: false

  @doc """
  Set the monthly model/subscription costs for a wallet — a `%{provider => cents}`
  map (integer cents, e.g. `%{"anthropic" => 2000}`). Written directly rather than
  through the cast changeset, so `update_wallet/2` can never overwrite it by
  accident (same guard as the cached `balance_cents`).
  """
  def set_model_costs(%Wallet{} = wallet, costs) when is_map(costs) do
    wallet
    |> Ecto.Changeset.change(model_costs: costs)
    |> Repo.update()
    |> broadcast_change(:updated)
  end

  @doc """
  Cost summary for a BusterClaw-template wallet: the BusterPhone number and its
  running (lifetime) telephony spend, plus the configured monthly model
  subscription costs and their sum. All money is integer cents.
  """
  def busterclaw_summary(%Wallet{} = wallet) do
    stats = Telephony.stats()
    costs = normalize_model_costs(wallet.model_costs)

    %{
      phone_number: Telephony.our_number(),
      phone_spent_cents: micros_to_cents(stats.spent_micros),
      phone_pending?: stats.pending_cost > 0,
      voicemails: stats.voicemails,
      model_costs_cents: costs,
      model_total_cents: costs |> Map.values() |> Enum.sum()
    }
  end

  defp normalize_model_costs(costs) when is_map(costs) do
    costs
    |> Enum.map(fn {provider, value} -> {to_string(provider), to_cents(value)} end)
    |> Enum.reject(fn {_provider, cents} -> cents <= 0 end)
    |> Map.new()
  end

  defp normalize_model_costs(_costs), do: %{}

  # Twilio prices are micro-USD ($0.25 = 250_000); wallets speak integer cents.
  defp micros_to_cents(micros) when is_integer(micros), do: div(micros, 10_000)
  defp micros_to_cents(_micros), do: 0

  defp to_cents(value) when is_integer(value), do: value

  defp to_cents(value) when is_binary(value) do
    case Integer.parse(value) do
      {cents, _rest} -> cents
      :error -> 0
    end
  end

  defp to_cents(_value), do: 0

  # ---------------------------------------------------------------------------
  # Transactions
  # ---------------------------------------------------------------------------

  # Default cap so the ledger view never pulls a wallet's entire history in one
  # query. Callers wanting everything can pass `limit: :infinity`.
  @default_transaction_limit 500

  @doc """
  List a wallet's transactions, newest first.

  Options:
    * `:limit`  — max rows (default `#{@default_transaction_limit}`; `:infinity` for no cap)
    * `:offset` — rows to skip, for paging
  """
  def list_transactions(wallet, opts \\ [])

  def list_transactions(%Wallet{} = wallet, opts), do: list_transactions(wallet.id, opts)

  def list_transactions(wallet_id, opts) do
    limit = Keyword.get(opts, :limit, @default_transaction_limit)
    offset = Keyword.get(opts, :offset, 0)

    Transaction
    |> where([t], t.wallet_id == ^wallet_id)
    |> order_by([t], desc: t.occurred_on, desc: t.inserted_at)
    |> maybe_limit(limit)
    |> maybe_offset(offset)
    |> Repo.all()
  end

  defp maybe_limit(query, :infinity), do: query
  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit), do: limit(query, ^limit)

  defp maybe_offset(query, offset) when is_integer(offset) and offset > 0,
    do: offset(query, ^offset)

  defp maybe_offset(query, _offset), do: query

  def change_transaction(%Transaction{} = transaction \\ %Transaction{}, attrs \\ %{}) do
    Transaction.changeset(transaction, attrs)
  end

  @doc """
  Insert a transaction and recompute the wallet's cached balance atomically.
  """
  def add_transaction(%Wallet{} = wallet, attrs) do
    attrs = normalize_transaction_attrs(wallet, attrs)

    multi_result =
      Repo.transaction(fn ->
        case %Transaction{} |> Transaction.changeset(attrs) |> Repo.insert() do
          {:ok, transaction} ->
            {recompute_balance!(wallet.id), transaction}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case multi_result do
      {:ok, {updated_wallet, transaction}} ->
        broadcast({:wallet_transaction, :created, transaction})
        broadcast({:wallet_changed, :updated, updated_wallet})
        {:ok, transaction}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_transaction(%Transaction{} = transaction) do
    result =
      Repo.transaction(fn ->
        case Repo.delete(transaction) do
          {:ok, deleted} -> {recompute_balance!(transaction.wallet_id), deleted}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, {updated_wallet, deleted}} ->
        broadcast({:wallet_transaction, :deleted, deleted})
        broadcast({:wallet_changed, :updated, updated_wallet})
        {:ok, deleted}

      other ->
        other
    end
  end

  # Sum income, subtract expense; write the result onto the wallet row.
  defp recompute_balance!(wallet_id) do
    income =
      Transaction
      |> where([t], t.wallet_id == ^wallet_id and t.kind == "income")
      |> select([t], coalesce(sum(t.amount_cents), 0))
      |> Repo.one()

    expense =
      Transaction
      |> where([t], t.wallet_id == ^wallet_id and t.kind == "expense")
      |> select([t], coalesce(sum(t.amount_cents), 0))
      |> Repo.one()

    wallet = Repo.get!(Wallet, wallet_id)

    {:ok, updated} =
      wallet
      |> Ecto.Changeset.change(balance_cents: income - expense)
      |> Repo.update()

    updated
  end

  defp normalize_transaction_attrs(%Wallet{} = wallet, attrs) do
    attrs
    |> stringify_keys()
    |> Map.put("wallet_id", wallet.id)
    |> Map.put_new("occurred_on", Date.utc_today())
    |> Map.put_new("source", "manual")
  end

  # ---------------------------------------------------------------------------
  # Budgets (personal wallets)
  # ---------------------------------------------------------------------------

  def list_budgets(%Wallet{} = wallet), do: list_budgets(wallet.id)

  def list_budgets(wallet_id) do
    Budget
    |> where([b], b.wallet_id == ^wallet_id)
    |> order_by([b], desc: b.month)
    |> Repo.all()
  end

  def get_budget(%Wallet{} = wallet, month), do: get_budget(wallet.id, month)

  def get_budget(wallet_id, month) do
    Repo.get_by(Budget, wallet_id: wallet_id, month: month)
  end

  def change_budget(%Budget{} = budget \\ %Budget{}, attrs \\ %{}) do
    Budget.changeset(budget, attrs)
  end

  @doc """
  Create or update the budget for a wallet/month (keyed on `[:wallet_id, :month]`).
  """
  def upsert_budget(%Wallet{} = wallet, attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("wallet_id", wallet.id)
    month = Map.get(attrs, "month")

    base = (month && get_budget(wallet.id, month)) || %Budget{}

    base
    |> Budget.changeset(attrs)
    |> Repo.insert_or_update()
    |> resolve_budget_race(wallet.id, month, attrs)
    |> broadcast_budget()
  end

  # A concurrent writer can insert the [wallet_id, month] row between our read and
  # our insert; the unique index then trips as a changeset error. Rather than
  # surface a spurious "has already been taken", re-read the winning row and apply
  # our update on top of it.
  defp resolve_budget_race({:error, changeset} = result, wallet_id, month, attrs)
       when is_binary(month) do
    if unique_conflict?(changeset) do
      case get_budget(wallet_id, month) do
        %Budget{} = existing -> existing |> Budget.changeset(attrs) |> Repo.update()
        nil -> result
      end
    else
      result
    end
  end

  defp resolve_budget_race(result, _wallet_id, _month, _attrs), do: result

  defp unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  @doc """
  Actuals vs. targets for a wallet in a given `"YYYY-MM"` month.

  Returns income/expense actuals (summed from transactions), the configured
  targets (zeros when no budget row exists), and a derived `savings_actual_cents`
  (income − expense).
  """
  def budget_summary(%Wallet{} = wallet, month), do: budget_summary(wallet.id, month)

  def budget_summary(wallet_id, month) do
    income_actual = sum_for_month(wallet_id, "income", month)
    expense_actual = sum_for_month(wallet_id, "expense", month)
    budget = get_budget(wallet_id, month)

    %{
      month: month,
      income_actual_cents: income_actual,
      expense_actual_cents: expense_actual,
      savings_actual_cents: income_actual - expense_actual,
      income_target_cents: budget && budget.income_target_cents,
      expense_target_cents: budget && budget.expense_target_cents,
      savings_target_cents: budget && budget.savings_target_cents
    }
  end

  defp sum_for_month(wallet_id, kind, month) do
    Transaction
    |> where([t], t.wallet_id == ^wallet_id and t.kind == ^kind)
    |> where([t], fragment("strftime('%Y-%m', ?)", t.occurred_on) == ^month)
    |> select([t], coalesce(sum(t.amount_cents), 0))
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # Feeds (external polling sources)
  # ---------------------------------------------------------------------------

  def list_feeds(%Wallet{} = wallet), do: list_feeds(wallet.id)

  def list_feeds(wallet_id) do
    Feed
    |> where([f], f.wallet_id == ^wallet_id)
    |> order_by([f], asc: f.kind, asc: f.inserted_at)
    |> Repo.all()
  end

  def get_feed!(id), do: Repo.get!(Feed, id)

  def change_feed(%Feed{} = feed \\ %Feed{}, attrs \\ %{}), do: Feed.changeset(feed, attrs)

  def create_feed(%Wallet{} = wallet, attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("wallet_id", wallet.id)

    %Feed{}
    |> Feed.changeset(attrs)
    |> Repo.insert()
    |> broadcast_feed(:created)
  end

  def update_feed(%Feed{} = feed, attrs) do
    feed
    |> Feed.changeset(attrs)
    |> Repo.update()
    |> broadcast_feed(:updated)
  end

  def delete_feed(%Feed{} = feed) do
    feed
    |> Repo.delete()
    |> broadcast_feed(:deleted)
  end

  @doc """
  Poll every enabled, timer-driven feed that is due (past its interval).

  `opts` may inject `:finance` and `:fetch` functions for deterministic tests;
  they default to `Finance.quote/1` and `Browser.fetch/1`.
  """
  def poll_due_feeds(opts \\ []) do
    now = timestamp()

    Feed
    |> where([f], f.enabled == true and f.kind in ^Feed.polled_kinds())
    |> Repo.all()
    |> Enum.filter(&due?(&1, now))
    |> Enum.map(&poll_feed(&1, opts))
  end

  @doc "Immediately poll all of a wallet's enabled timer-driven feeds (manual trigger)."
  def poll_wallet_feeds(%Wallet{} = wallet, opts \\ []) do
    Feed
    |> where(
      [f],
      f.wallet_id == ^wallet.id and f.enabled == true and f.kind in ^Feed.polled_kinds()
    )
    |> Repo.all()
    |> Enum.map(&poll_feed(&1, opts))
  end

  @doc "Poll a single feed now, recording status/value and broadcasting the change."
  def poll_feed(%Feed{kind: "market"} = feed, opts) do
    finance = Keyword.get(opts, :finance, &Finance.quote/1)
    symbol = feed.config["symbol"]

    case finance.(symbol) do
      {:ok, %{price: price} = quote} ->
        finish_feed(feed, %{
          last_status: "ok",
          last_error: nil,
          last_value: format_price(symbol, price),
          last_run_at: timestamp(),
          metadata_source: Map.take(quote, [:source, :as_of, :percent_change])
        })

      {:error, reason} ->
        fail_feed(feed, reason)
    end
  end

  def poll_feed(%Feed{kind: "url"} = feed, opts) do
    fetch = Keyword.get(opts, :fetch, &Browser.fetch/1)
    url = feed.config["url"]

    case fetch.(url) do
      {:ok, page} ->
        hash = Library.body_hash(page.markdown || page.html || "")
        changed = feed.last_content_hash != nil and hash != feed.last_content_hash

        finish_feed(feed, %{
          last_status: "ok",
          last_error: nil,
          last_content_hash: hash,
          last_value:
            if(changed, do: "changed", else: "unchanged") <> " · " <> (page.title || url),
          last_run_at: timestamp()
        })

      {:error, reason} ->
        fail_feed(feed, reason)
    end
  end

  def poll_feed(%Feed{kind: "integration"} = feed, _opts) do
    case latest_integration_summary(feed.config["integration_id"]) do
      {:ok, value} ->
        finish_feed(feed, %{
          last_status: "ok",
          last_error: nil,
          last_value: value,
          last_run_at: timestamp()
        })

      {:error, reason} ->
        fail_feed(feed, reason)
    end
  end

  def poll_feed(%Feed{} = feed, _opts), do: {:ok, feed}

  @doc """
  Record an inbound Gmail receipt against every enabled `gmail` feed. Amount
  extraction is intentionally deferred — this records the signal (sender/subject)
  and a running count so a wallet surfaces that receipts are arriving.
  """
  def record_gmail_signal(item) do
    label = "#{value(item, :sender) || "unknown"}: #{value(item, :subject) || "(no subject)"}"

    Feed
    |> where([f], f.kind == "gmail" and f.enabled == true)
    |> Repo.all()
    |> Enum.map(fn feed ->
      finish_feed(feed, %{
        last_status: "ok",
        last_error: nil,
        last_value: label,
        last_run_at: timestamp()
      })
    end)
  end

  @doc "Refresh `integration` feeds bound to the integration whose run just completed."
  def record_integration_run(run) do
    integration_id = value(run, :integration_id)

    Feed
    |> where([f], f.kind == "integration" and f.enabled == true)
    |> Repo.all()
    |> Enum.filter(&(to_string(&1.config["integration_id"]) == to_string(integration_id)))
    |> Enum.map(fn feed ->
      finish_feed(feed, %{
        last_status: "ok",
        last_error: nil,
        last_value: "#{value(run, :records_fetched) || 0} records",
        last_run_at: timestamp()
      })
    end)
  end

  defp due?(%Feed{last_run_at: nil}, _now), do: true

  defp due?(%Feed{last_run_at: last, polling_interval_minutes: interval}, now) do
    DateTime.diff(now, last, :minute) >= interval
  end

  defp finish_feed(%Feed{} = feed, attrs) do
    {_source, attrs} = Map.pop(attrs, :metadata_source)

    feed
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
    |> broadcast_feed(:polled)
  end

  defp fail_feed(%Feed{} = feed, reason) do
    finish_feed(feed, %{
      last_status: "error",
      last_error: feed_error_message(reason),
      last_run_at: timestamp()
    })
  end

  defp latest_integration_summary(nil), do: {:error, :missing_integration_id}

  defp latest_integration_summary(integration_id) do
    alias BusterClaw.Integrations

    case Integrations.list_runs()
         |> Enum.find(&(to_string(&1.integration_id) == to_string(integration_id))) do
      nil -> {:error, :no_runs}
      run -> {:ok, "#{run.records_fetched} records · #{run.status}"}
    end
  end

  defp format_price(symbol, price) when is_number(price), do: "#{symbol}: #{price}"
  defp format_price(symbol, _price), do: "#{symbol}: n/a"

  defp feed_error_message(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp feed_error_message(reason), do: reason |> inspect() |> String.slice(0, 500)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp broadcast_change({:ok, wallet} = result, event) do
    broadcast({:wallet_changed, event, wallet})
    result
  end

  defp broadcast_change(result, _event), do: result

  defp broadcast_budget({:ok, budget} = result) do
    broadcast({:wallet_budget_changed, budget})
    result
  end

  defp broadcast_budget(result), do: result

  defp broadcast_feed({:ok, feed} = result, event) do
    broadcast({:wallet_feed_changed, event, feed})
    result
  end

  defp broadcast_feed(result, _event), do: result

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, message)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp value(_map, _key), do: nil
end
