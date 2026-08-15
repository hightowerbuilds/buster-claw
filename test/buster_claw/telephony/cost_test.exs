defmodule BusterClaw.Telephony.CostTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Telephony

  setup do
    prev = Application.get_env(:buster_claw, :twilio)
    Application.put_env(:buster_claw, :twilio, %{account_sid: "AC_test", auth_token: "tok"})
    on_exit(fn -> Application.put_env(:buster_claw, :twilio, prev) end)
    :ok
  end

  defp opts, do: [req_options: [plug: {Req.Test, BusterClaw.TwilioCostHTTP}]]

  defp stub(prices) do
    Req.Test.stub(BusterClaw.TwilioCostHTTP, fn conn ->
      cond do
        String.contains?(conn.request_path, "/Transcriptions.json") ->
          Req.Test.json(conn, %{"transcriptions" => prices[:transcriptions] || []})

        String.contains?(conn.request_path, "/Recordings/") ->
          Req.Test.json(conn, %{
            "price" => prices[:recording],
            "price_unit" => "USD",
            "call_sid" => "CA123"
          })

        String.contains?(conn.request_path, "/Calls/") ->
          Req.Test.json(conn, %{"price" => prices[:call], "price_unit" => "USD"})
      end
    end)
  end

  defp voicemail(attrs \\ %{}) do
    {:ok, event} =
      Telephony.record_event(
        Map.merge(
          %{
            direction: "inbound",
            kind: "voicemail",
            from_number: "+15033412655",
            to_number: "+13603646763",
            twilio_sid: "RE#{System.unique_integer([:positive])}",
            occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        ),
        observe: false
      )

    event
  end

  test "refresh_cost stores the total and finalizes when all components price" do
    event = voicemail()

    stub(%{call: "-0.00850", recording: "-0.00250", transcriptions: [%{"price" => "-0.20"}]})

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_micros == 211_000
    assert updated.cost_currency == "USD"
    assert updated.cost_synced_at != nil

    assert updated.metadata["cost_breakdown"] == %{
             "call" => 8500,
             "recording" => 2500,
             "transcription" => 200_000
           }
  end

  test "an unpriced component leaves the row provisional (no synced_at, still in the work list)" do
    event = voicemail()

    stub(%{call: "-0.00850", recording: nil, transcriptions: [%{"price" => "-0.20"}]})

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_micros == 208_500
    assert updated.cost_synced_at == nil
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [updated.id]
  end

  test "a voicemail without a RecordingSid can't be priced" do
    event = voicemail(%{twilio_sid: nil})
    assert {:error, :no_sids} = Telephony.refresh_cost(event, opts())
  end

  test "unpriced_events lists only unfinalized rows" do
    a = voicemail()
    _b = voicemail()

    stub(%{call: "-0.01", recording: "-0.01", transcriptions: [%{"price" => "-0.01"}]})
    {:ok, _} = Telephony.refresh_cost(a, opts())

    ids = Telephony.unpriced_events() |> Enum.map(& &1.id) |> Enum.sort()
    refute a.id in ids
    assert length(ids) == 1
  end

  test "refresh_unpriced_costs no-ops when Twilio isn't configured" do
    Application.put_env(:buster_claw, :twilio, %{})
    _event = voicemail()
    assert :ok = Telephony.refresh_unpriced_costs(opts())
    # Nothing priced — the row is still in the work list.
    assert length(Telephony.unpriced_events()) == 1
  end

  # --- outbound bridged calls: TWO legs ------------------------------------
  #
  # The parent is the call we created (it rings the operator); `<Dial>` creates a
  # child call for the far end, which Twilio prices as its own resource. Summing
  # the parent alone halves the bill and looks settled while doing it.

  defp outbound_call(attrs \\ %{}) do
    {:ok, event} =
      Telephony.record_event(
        Map.merge(
          %{
            direction: "outbound",
            kind: "call",
            from_number: "+13603646763",
            to_number: "+15035550142",
            twilio_sid: "CA#{System.unique_integer([:positive])}",
            occurred_at: DateTime.utc_now(:second)
          },
          attrs
        ),
        observe: false
      )

    event
  end

  # `parent` is the leg we created, `children` the ones `<Dial>` made.
  defp stub_call(parent, children) do
    Req.Test.stub(BusterClaw.TwilioCostHTTP, fn conn ->
      if String.ends_with?(conn.request_path, "/Calls.json") do
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["ParentCallSid"], "child legs must be scoped to the parent"
        Req.Test.json(conn, %{"calls" => children})
      else
        Req.Test.json(conn, parent)
      end
    end)
  end

  defp leg(price, status \\ "completed"),
    do: %{"price" => price, "price_unit" => "USD", "status" => status}

  test "a bridged call prices BOTH legs, not just the one we created" do
    event = outbound_call()
    stub_call(leg("-0.0140"), [leg("-0.0220")])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())

    # 0.014 + 0.022 — the parent alone would have read $0.0140 and looked final.
    assert updated.cost_micros == 36_000
    assert updated.cost_currency == "USD"
    assert updated.cost_synced_at != nil

    assert updated.metadata["cost_breakdown"] == %{"your_leg" => 14_000, "their_leg" => 22_000}
  end

  test "a call nobody answered has one leg, and that is final" do
    event = outbound_call()

    # The operator never picked up, so `<Dial>` never ran and there is no child.
    # Treating an empty child list as pending — which is what the voicemail path
    # does for transcriptions — would retry this row forever.
    stub_call(leg("-0.0060", "no-answer"), [])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_micros == 6_000
    assert updated.cost_synced_at != nil
    assert updated.metadata["cost_breakdown"] == %{"your_leg" => 6_000, "their_leg" => 0}
  end

  test "a call still in progress is provisional even when both legs report a price" do
    event = outbound_call()

    # Deliberately inconsistent, and that is the point: `price` and `status` are
    # separate fields on the same resource, and this code does not get to assume
    # a priced call has ended. If it did, a partially-billed in-flight call would
    # finalize at whatever it happened to cost so far and never be corrected.
    stub_call(leg("-0.0140", "in-progress"), [leg("-0.0220")])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_micros == 36_000
    assert updated.cost_synced_at == nil
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [updated.id]
  end

  test "an in-flight call with no child yet is provisional too" do
    event = outbound_call()
    stub_call(leg(nil, "in-progress"), [])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_synced_at == nil
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [updated.id]
  end

  test "an unpriced child leg keeps the row in the work list" do
    event = outbound_call()
    stub_call(leg("-0.0140"), [leg(nil)])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_micros == 14_000
    assert updated.cost_synced_at == nil
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [updated.id]
  end

  test "an outbound call is in the work list; an inbound one never is" do
    outbound = outbound_call()
    _inbound = outbound_call(%{direction: "inbound"})

    # An inbound leg frequently never prices at all. Including it would fill an
    # oldest-first, limited work list with rows that can never finalize.
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [outbound.id]
  end

  test "a row that can never price is given up on rather than starving the list" do
    old = DateTime.utc_now(:second) |> DateTime.add(-8, :day)
    event = outbound_call(%{occurred_at: old})

    # Terminal, but the price never settled — a deleted resource, or a plan that
    # does not per-call price. Without a give-up this row sits at the head of an
    # oldest-first list forever.
    stub_call(leg(nil), [leg(nil)])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_synced_at != nil
    assert updated.metadata["cost_incomplete"] == true
    assert Telephony.unpriced_events() == []
  end

  test "a young row with the same missing prices is NOT given up on" do
    event = outbound_call()
    stub_call(leg(nil), [leg(nil)])

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_synced_at == nil
    refute updated.metadata["cost_incomplete"]
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [updated.id]
  end
end
