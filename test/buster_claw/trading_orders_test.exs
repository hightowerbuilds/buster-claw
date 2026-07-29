defmodule BusterClaw.TradingOrdersTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.TradingOrderBrokerFake
  alias BusterClaw.TradingOrders

  @policy [
    max_notional_cents: 100_000,
    max_concentration_bps: 2_500,
    max_quote_age_seconds: 30,
    blocked_symbols: [],
    allow_market_orders_outside_hours: true
  ]

  setup do
    Application.put_env(:buster_claw, :trading_order_broker_observer, self())
    Process.delete({TradingOrderBrokerFake, :review})
    Process.delete({TradingOrderBrokerFake, :submit})
    Process.delete({TradingOrderBrokerFake, :submit_count})
    Process.delete({TradingOrderBrokerFake, :fetch_order})

    on_exit(fn ->
      Application.delete_env(:buster_claw, :trading_order_broker_observer)
    end)

    :ok
  end

  test "parses only the narrow, explicit order command grammar" do
    assert {:ok, attrs} =
             TradingOrders.parse_command(
               "/order buy $250 AAPL limit 190.25 day account=agentic-account-opaque"
             )

    assert attrs == %{
             "account_id" => "agentic-account-opaque",
             "amount" => "250",
             "amount_type" => "notional",
             "limit_price" => "190.25",
             "order_type" => "limit",
             "side" => "buy",
             "symbol" => "AAPL",
             "time_in_force" => "day"
           }

    assert {:error, :invalid_order_command} =
             TradingOrders.parse_command("buy everything in AAPL")

    assert {:error, :invalid_order_command} =
             TradingOrders.parse_command("/order buy 2 AAPL market day account=agentic account")
  end

  test "persists an exact non-executable draft and creation event" do
    assert {:ok, intent} = create_draft()
    assert intent.status == "draft"
    assert intent.quantity_micros == 2_000_000
    assert intent.notional_cents == nil
    assert intent.limit_price_cents == nil
    assert is_binary(intent.client_order_id)

    assert [event] = TradingOrders.events(intent.public_id)
    assert event.event_type == "draft_created"
    assert event.payload["quantity_micros"] == 2_000_000
  end

  test "production review fails closed without a connected opaque account" do
    assert {:ok, intent} = create_draft()

    assert {:error, :broker_account_not_found} =
             TradingOrders.preview(intent.public_id)

    assert TradingOrders.get(intent.public_id).status == "draft"
  end

  test "dollar notional is rejected for limit orders" do
    assert {:error, changeset} =
             TradingOrders.create_draft(%{
               "account_id" => "agentic-account-opaque",
               "side" => "buy",
               "symbol" => "AAPL",
               "amount_type" => "notional",
               "amount" => "250",
               "order_type" => "limit",
               "limit_price" => "190.25",
               "time_in_force" => "day"
             })

    assert {"is only supported for market orders", _metadata} =
             changeset.errors[:notional_cents]
  end

  test "review, exact confirmation, submission, and reconciliation are fully audited" do
    assert {:ok, draft} = create_draft()

    assert {:ok, %{intent: preview, confirmation_phrase: phrase}} =
             TradingOrders.preview(draft.public_id,
               broker: TradingOrderBrokerFake,
               policy: @policy
             )

    assert_received {:broker_reviewed, request}
    assert request["client_order_id"] == draft.client_order_id
    assert preview.status == "previewed"
    assert preview.preview_payload["broker_preview_id"] == "review-opaque-123"

    assert preview.preview_payload["broker_preview"] == %{
             "warnings" => [],
             "estimated_fee_cents" => 0
           }

    assert preview.confirmation_expires_at
    refute preview.confirmation_digest == phrase
    refute inspect(preview) =~ phrase

    assert {:ok, submitted} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               preview.preview_digest,
               phrase,
               broker: TradingOrderBrokerFake
             )

    assert_received {:broker_submitted, public_id, client_order_id}
    assert public_id == draft.public_id
    assert client_order_id == draft.client_order_id
    assert submitted.status == "accepted"
    assert submitted.broker_order_id == "broker-order-456"

    assert {:ok, filled} =
             TradingOrders.reconcile(draft.public_id, broker: TradingOrderBrokerFake)

    assert_received {:broker_fetched, ^public_id}
    assert filled.status == "filled"

    assert Enum.map(TradingOrders.events(draft.public_id), & &1.event_type) == [
             "draft_created",
             "preview_created",
             "confirmation_accepted",
             "broker_submission_recorded",
             "broker_status_reconciled"
           ]
  end

  test "replay and payload tampering never call submit" do
    assert {:ok, draft} = create_draft()

    assert {:ok, %{intent: preview, confirmation_phrase: phrase}} =
             TradingOrders.preview(draft.public_id,
               broker: TradingOrderBrokerFake,
               policy: @policy
             )

    assert {:error, :preview_tampered} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               String.duplicate("0", 64),
               phrase,
               broker: TradingOrderBrokerFake
             )

    assert Process.get({TradingOrderBrokerFake, :submit_count}, 0) == 0

    assert {:ok, _submitted} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               preview.preview_digest,
               phrase,
               broker: TradingOrderBrokerFake
             )

    assert {:error, :confirmation_replayed} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               preview.preview_digest,
               phrase,
               broker: TradingOrderBrokerFake
             )

    assert Process.get({TradingOrderBrokerFake, :submit_count}) == 1
  end

  test "expired and mismatched confirmations never call submit" do
    now = DateTime.utc_now()
    assert {:ok, draft} = create_draft()

    assert {:ok, %{intent: preview, confirmation_phrase: phrase}} =
             TradingOrders.preview(draft.public_id,
               broker: TradingOrderBrokerFake,
               policy: @policy,
               now: now,
               confirmation_ttl_seconds: 1
             )

    assert {:error, :confirmation_phrase_mismatch} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               preview.preview_digest,
               phrase <> "!",
               broker: TradingOrderBrokerFake,
               now: now
             )

    assert {:error, :confirmation_expired} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               preview.preview_digest,
               phrase,
               broker: TradingOrderBrokerFake,
               now: DateTime.add(now, 2, :second)
             )

    assert Process.get({TradingOrderBrokerFake, :submit_count}, 0) == 0
    assert TradingOrders.get(draft.public_id).status == "expired"
    assert List.last(TradingOrders.events(draft.public_id)).event_type == "confirmation_expired"
  end

  test "ambiguous submission outcomes remain unknown and are reconciled by id" do
    Process.put(
      {TradingOrderBrokerFake, :submit},
      {:error, {:unknown, :connection_closed_after_write}}
    )

    assert {:ok, draft} = create_draft()

    assert {:ok, %{intent: preview, confirmation_phrase: phrase}} =
             TradingOrders.preview(draft.public_id,
               broker: TradingOrderBrokerFake,
               policy: @policy
             )

    assert {:ok, unknown} =
             TradingOrders.confirm_and_submit(
               draft.public_id,
               preview.preview_digest,
               phrase,
               broker: TradingOrderBrokerFake
             )

    assert unknown.status == "unknown"
    assert unknown.failure_reason =~ "connection_closed_after_write"

    assert {:ok, filled} =
             TradingOrders.reconcile(draft.public_id, broker: TradingOrderBrokerFake)

    assert filled.status == "filled"
  end

  test "policy blocks stale, oversized, concentrated, and underfunded reviews" do
    now = DateTime.utc_now()

    scenarios = [
      {%{broker_timestamp: DateTime.add(now, -31, :second)}, :stale_broker_review},
      {%{estimated_notional_cents: 100_001}, :notional_limit_exceeded},
      {%{concentration_bps: 2_501}, :concentration_limit_exceeded},
      {%{buying_power_cents: 1}, :insufficient_buying_power}
    ]

    Enum.each(scenarios, fn {override, expected} ->
      Process.put(
        {TradingOrderBrokerFake, :review},
        {:ok, Map.merge(valid_review(now), override)}
      )

      assert {:ok, draft} = create_draft()

      assert {:error, ^expected} =
               TradingOrders.preview(draft.public_id,
                 broker: TradingOrderBrokerFake,
                 policy: @policy,
                 now: now
               )

      assert TradingOrders.get(draft.public_id).status == "draft"
    end)
  end

  defp create_draft do
    TradingOrders.create_draft(%{
      "account_id" => "agentic-account-opaque",
      "account_label" => "Agentic",
      "symbol" => "AAPL",
      "side" => "buy",
      "amount_type" => "quantity",
      "amount" => "2",
      "order_type" => "market",
      "limit_price" => "",
      "time_in_force" => "day"
    })
  end

  defp valid_review(now) do
    %{
      quote_cents: 19_925,
      buying_power_cents: 500_000,
      estimated_notional_cents: 39_850,
      concentration_bps: 1_200,
      market_open: true,
      broker_preview: %{"warnings" => [], "estimated_fee_cents" => 0},
      broker_preview_id: "review-opaque-123",
      broker_timestamp: now
    }
  end
end
