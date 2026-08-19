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

  # --- legacy call rows: in the ledger, out of the work list ---------------
  #
  # Outbound calling was deleted on 08-18 (PHONE_INTAKE_ROADMAP Phase 2) and the
  # rows it created deliberately STAYED — they are a true record of what
  # happened. What went with it was the only code that could ever price them.

  defp legacy_call(attrs \\ %{}) do
    {:ok, event} =
      Telephony.record_event(
        Map.merge(
          %{
            direction: "outbound",
            kind: "call",
            from_number: "+13603646763",
            to_number: "+15035550142",
            # A CallSid, not a RecordingSid — the shape `cost_for/2` no longer
            # prices, and the reason these rows can never finalize.
            twilio_sid: "CA#{System.unique_integer([:positive])}",
            occurred_at: DateTime.utc_now(:second)
          },
          attrs
        ),
        observe: false
      )

    event
  end

  # THE STARVATION BUG, pinned.
  #
  # `unpriced_events/1` used to select `kind == "voicemail" OR (kind == "call"
  # AND direction == "outbound")`, which was correct while outbound calls had a
  # pricing clause. With that clause deleted every one of those rows answers
  # `{:error, :missing_sids}` forever, so `cost_synced_at` stays `nil` and they
  # stay in the list. The list is **oldest-first with a limit of 25** — and the
  # legacy rows are, by construction, older than every voicemail that will ever
  # be recorded again. Twenty-five of them is one quiet week of a feature that
  # no longer exists, and after that no voicemail is ever priced again: no
  # error, no log, the drain reporting a clean tick every time.
  #
  # The fix is that the `where` clause names ONE kind. This test is what says so.
  test "legacy outbound call rows never enter the work list, however old they are" do
    old = DateTime.utc_now(:second) |> DateTime.add(-30, :day)

    legacy_a = legacy_call(%{occurred_at: old})
    legacy_b = legacy_call(%{occurred_at: DateTime.add(old, 1, :day)})

    # Inbound call rows are excluded for the same reason and were already
    # excluded before — asserted here so the two exclusions share a guard, since
    # it is now the KIND that rules both out and no longer the direction.
    inbound = legacy_call(%{direction: "inbound", occurred_at: DateTime.add(old, 2, :day)})

    # Newest of the four, so an oldest-first query only reaches it once all
    # three call rows are out of the way.
    vm = voicemail()

    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [vm.id],
           "a call row in the work list starves every voicemail behind it"

    # And the other half of why they must not be queued: there is no route that
    # could ever take them out again.
    for row <- [legacy_a, legacy_b, inbound] do
      assert {:error, :no_sids} = Telephony.refresh_cost(row, opts())
      assert Repo.reload!(row).cost_synced_at == nil
    end
  end

  # --- giving up, so one bad row cannot starve the list --------------------

  test "a voicemail that can never price is given up on rather than starving the list" do
    old = DateTime.utc_now(:second) |> DateTime.add(-8, :day)
    event = voicemail(%{occurred_at: old})

    # Terminal, but nothing settled — a deleted recording, or a plan that does
    # not per-component price. Without a give-up this row sits at the head of an
    # oldest-first list forever, which is the same failure the test above pins
    # from the other direction.
    stub(%{call: nil, recording: nil, transcriptions: []})

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_synced_at != nil
    assert updated.metadata["cost_incomplete"] == true
    assert Telephony.unpriced_events() == []
  end

  test "a young row with the same missing prices is NOT given up on" do
    event = voicemail()
    stub(%{call: nil, recording: nil, transcriptions: []})

    assert {:ok, updated} = Telephony.refresh_cost(event, opts())
    assert updated.cost_synced_at == nil
    refute updated.metadata["cost_incomplete"]
    assert Enum.map(Telephony.unpriced_events(), & &1.id) == [updated.id]
  end
end
