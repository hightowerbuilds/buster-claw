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
    assert Enum.map(Telephony.unpriced_voicemails(), & &1.id) == [updated.id]
  end

  test "a voicemail without a RecordingSid can't be priced" do
    event = voicemail(%{twilio_sid: nil})
    assert {:error, :no_sids} = Telephony.refresh_cost(event, opts())
  end

  test "unpriced_voicemails lists only unfinalized voicemails" do
    a = voicemail()
    _b = voicemail()

    stub(%{call: "-0.01", recording: "-0.01", transcriptions: [%{"price" => "-0.01"}]})
    {:ok, _} = Telephony.refresh_cost(a, opts())

    ids = Telephony.unpriced_voicemails() |> Enum.map(& &1.id) |> Enum.sort()
    refute a.id in ids
    assert length(ids) == 1
  end

  test "refresh_unpriced_costs no-ops when Twilio isn't configured" do
    Application.put_env(:buster_claw, :twilio, %{})
    _event = voicemail()
    assert :ok = Telephony.refresh_unpriced_costs(opts())
    # Nothing priced — the row is still in the work list.
    assert length(Telephony.unpriced_voicemails()) == 1
  end
end
