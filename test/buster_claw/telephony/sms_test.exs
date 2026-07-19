defmodule BusterClaw.Telephony.SmsTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Sentinel
  alias BusterClaw.Telephony

  setup do
    previous = Application.get_env(:buster_claw, :twilio)

    Application.put_env(:buster_claw, :twilio, %{
      account_sid: "AC_test",
      auth_token: "tok",
      messaging_service_sid: "MG_test",
      sms_enabled: true
    })

    on_exit(fn -> Application.put_env(:buster_claw, :twilio, previous) end)
    Req.Test.verify_on_exit!()
    :ok
  end

  defp opts do
    [
      daily_cap: 1,
      req_options: [plug: {Req.Test, BusterClaw.SmsHTTP}]
    ]
  end

  test "accepted SMS is persisted, audited, and counts toward the daily cap" do
    Req.Test.expect(BusterClaw.SmsHTTP, fn conn ->
      Req.Test.json(conn, %{
        "sid" => "SM_local",
        "status" => "accepted",
        "to" => "+15035550123",
        "from" => "+13603646763",
        "messaging_service_sid" => "MG_test"
      })
    end)

    assert {:ok, result} = Telephony.send_sms("(503) 555-0123", "Status is green.", opts())
    assert result.sent
    assert result.persisted
    assert result.to == "+15035550123"
    assert result.twilio_sid == "SM_local"

    assert [event] = Telephony.list_events(kind: "sms")
    assert event.direction == "outbound"
    assert event.from_number == "+13603646763"
    assert event.to_number == "+15035550123"
    assert event.body == "Status is green."
    assert event.metadata["twilio_status"] == "accepted"
    assert Telephony.sent_today_to("+15035550123") == 1

    assert Enum.any?(Sentinel.list_events(limit: 10), fn audit ->
             audit.category == "outbound_send" and
               audit.metadata["twilio_sid"] == "SM_local" and
               audit.metadata["persisted"] == true
           end)

    assert {:error, {:sms_daily_cap_reached, 1}} =
             Telephony.send_sms("+15035550123", "This must not leave the box.", opts())
  end

  test "invalid recipients and bodies are rejected before Twilio" do
    assert {:error, :invalid_recipient} = Telephony.send_sms("not a number", "Hello", opts())
    assert {:error, :empty_body} = Telephony.send_sms("+15035550123", "", opts())

    assert {:error, :body_too_long} =
             Telephony.send_sms("+15035550123", String.duplicate("x", 1601), opts())
  end

  test "an inbound STOP blocks outbound until a later START" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _stop} =
             Telephony.record_event(
               %{
                 direction: "inbound",
                 kind: "sms",
                 from_number: "+15035550123",
                 to_number: "+13603646763",
                 body: "STOP",
                 twilio_sid: "SM_stop",
                 occurred_at: occurred_at,
                 metadata: %{"opt_out_type" => "STOP"}
               },
               observe: false
             )

    assert Telephony.sms_opted_out?("+15035550123")

    assert {:error, :recipient_opted_out} =
             Telephony.send_sms("+15035550123", "This must not leave the box.", opts())

    assert {:ok, _start} =
             Telephony.record_event(
               %{
                 direction: "inbound",
                 kind: "sms",
                 from_number: "+15035550123",
                 to_number: "+13603646763",
                 body: "START",
                 twilio_sid: "SM_start",
                 occurred_at: occurred_at,
                 metadata: %{"opt_out_type" => "START"}
               },
               observe: false
             )

    refute Telephony.sms_opted_out?("+15035550123")
  end
end
