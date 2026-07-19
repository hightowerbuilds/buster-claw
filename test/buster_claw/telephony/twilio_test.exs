defmodule BusterClaw.Telephony.TwilioTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Telephony.Twilio

  setup do
    prev = Application.get_env(:buster_claw, :twilio)

    Application.put_env(:buster_claw, :twilio, %{
      account_sid: "AC_test",
      auth_token: "tok",
      messaging_service_sid: "MG_test",
      sms_enabled: true
    })

    on_exit(fn -> Application.put_env(:buster_claw, :twilio, prev) end)
    Req.Test.verify_on_exit!()
    :ok
  end

  defp opts, do: [req_options: [plug: {Req.Test, BusterClaw.TwilioHTTP}]]

  # Route the three cost resources off the request path; each test supplies the
  # prices it wants back.
  defp stub(prices) do
    Req.Test.stub(BusterClaw.TwilioHTTP, fn conn ->
      cond do
        String.contains?(conn.request_path, "/Transcriptions.json") ->
          Req.Test.json(conn, %{"transcriptions" => prices[:transcriptions] || []})

        String.contains?(conn.request_path, "/Recordings/") ->
          Req.Test.json(conn, %{
            "price" => prices[:recording],
            "price_unit" => "USD",
            "call_sid" => "CA1"
          })

        String.contains?(conn.request_path, "/Calls/") ->
          Req.Test.json(conn, %{"price" => prices[:call], "price_unit" => "USD"})
      end
    end)
  end

  test "configured? reflects presence of both creds" do
    assert Twilio.configured?()
    Application.put_env(:buster_claw, :twilio, %{account_sid: "AC", auth_token: ""})
    refute Twilio.configured?()
    Application.put_env(:buster_claw, :twilio, %{})
    refute Twilio.configured?()
  end

  test "price_micros parses Twilio's negative USD strings, nil, and numbers" do
    assert Twilio.price_micros("-0.00850") == 8500
    assert Twilio.price_micros("-0.25") == 250_000
    assert Twilio.price_micros(nil) == :pending
    assert Twilio.price_micros("") == :pending
    assert Twilio.price_micros(-0.05) == 50_000
    assert Twilio.price_micros("not-a-number") == :pending
  end

  test "cost_for sums call + recording + transcription and is final when all settled" do
    stub(%{
      call: "-0.00850",
      recording: "-0.00250",
      transcriptions: [%{"price" => "-0.20000"}]
    })

    assert {:ok, cost} =
             Twilio.cost_for(%{recording_sid: "RE1"}, opts())

    # 8500 + 2500 + 200000
    assert cost.total_micros == 211_000
    assert cost.currency == "USD"
    assert cost.final?
    assert cost.breakdown == %{call: 8500, recording: 2500, transcription: 200_000}
  end

  test "a still-unpriced component makes the result provisional (final? false)" do
    stub(%{
      call: "-0.00850",
      recording: nil,
      transcriptions: [%{"price" => "-0.20000"}]
    })

    assert {:ok, cost} = Twilio.cost_for(%{recording_sid: "RE1"}, opts())
    # Only the settled components sum; recording is pending.
    assert cost.total_micros == 208_500
    refute cost.final?
    assert cost.breakdown.recording == :pending
  end

  test "no transcription yet is pending (a recording awaiting its callback)" do
    stub(%{call: "-0.00850", recording: "-0.00250", transcriptions: []})

    assert {:ok, cost} = Twilio.cost_for(%{recording_sid: "RE1"}, opts())
    refute cost.final?
    assert cost.breakdown.transcription == :pending
    # Settled components still sum.
    assert cost.total_micros == 11_000
  end

  test "a null call leg (trial credit) still finalizes on recording + transcription" do
    stub(%{call: nil, recording: "-0.00250", transcriptions: [%{"price" => "-0.05000"}]})

    assert {:ok, cost} = Twilio.cost_for(%{recording_sid: "RE1"}, opts())
    # Real trial-voicemail shape: rec 0.0025 + txt 0.05, call unpriced.
    assert cost.total_micros == 52_500
    assert cost.final?
    assert cost.breakdown.call == :pending
  end

  test "multiple transcriptions sum" do
    stub(%{
      call: "-0.01",
      recording: "-0.01",
      transcriptions: [%{"price" => "-0.10"}, %{"price" => "-0.05"}]
    })

    assert {:ok, cost} = Twilio.cost_for(%{recording_sid: "RE1"}, opts())
    assert cost.breakdown.transcription == 150_000
    assert cost.total_micros == 170_000
    assert cost.final?
  end

  test "a missing RecordingSid is rejected without a request" do
    assert {:error, :missing_sids} = Twilio.cost_for(%{}, opts())
    assert {:error, :missing_sids} = Twilio.cost_for(%{recording_sid: nil}, opts())
  end

  describe "send_sms/3" do
    test "posts the recipient, body, and Messaging Service SID" do
      test_pid = self()

      Req.Test.expect(BusterClaw.TwilioHTTP, fn conn ->
        {:ok, encoded, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sms_request, conn.request_path, URI.decode_query(encoded)})

        Req.Test.json(conn, %{
          "sid" => "SM_sent",
          "status" => "accepted",
          "to" => "+15035550123",
          "from" => "+13603646763",
          "messaging_service_sid" => "MG_test"
        })
      end)

      assert {:ok, receipt} =
               Twilio.send_sms("+15035550123", "Status is green.", opts())

      assert_received {:sms_request, "/2010-04-01/Accounts/AC_test/Messages.json", form}
      assert form["To"] == "+15035550123"
      assert form["Body"] == "Status is green."
      assert form["MessagingServiceSid"] == "MG_test"
      assert receipt.sid == "SM_sent"
      assert receipt.status == "accepted"
      assert receipt.from == "+13603646763"
    end

    test "fails closed when the SMS kill switch is off" do
      Application.put_env(:buster_claw, :twilio, %{
        account_sid: "AC_test",
        auth_token: "tok",
        messaging_service_sid: "MG_test",
        sms_enabled: false
      })

      assert {:error, :sms_disabled} =
               Twilio.send_sms("+15035550123", "No send", opts())
    end

    test "requires a Messaging Service and validates Twilio limits" do
      Application.put_env(:buster_claw, :twilio, %{
        account_sid: "AC_test",
        auth_token: "tok",
        sms_enabled: true
      })

      assert {:error, :missing_messaging_service} =
               Twilio.send_sms("+15035550123", "No send", opts())

      Application.put_env(:buster_claw, :twilio, %{
        account_sid: "AC_test",
        auth_token: "tok",
        messaging_service_sid: "MG_test",
        sms_enabled: true
      })

      assert {:error, :invalid_recipient} = Twilio.send_sms("555", "No send", opts())
      assert {:error, :empty_body} = Twilio.send_sms("+15035550123", "  ", opts())

      assert {:error, :body_too_long} =
               Twilio.send_sms("+15035550123", String.duplicate("x", 1601), opts())
    end

    test "surfaces Twilio API errors without treating them as sent" do
      Req.Test.expect(BusterClaw.TwilioHTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"code" => 21_611, "message" => "Invalid To number"})
      end)

      assert {:error, {:twilio_status, 400, %{"code" => 21_611}}} =
               Twilio.send_sms("+15035550123", "No send", opts())
    end
  end
end
