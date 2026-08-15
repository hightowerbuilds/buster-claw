defmodule BusterClaw.Telephony.CallTest do
  @moduledoc """
  Outbound bridged calling (`OUTBOUND_VOICE_ROADMAP`).

  The shape being proven, because it is unusual: **two legs, and the operator's
  own phone is the first one.** `To` on the request is the operator, not the
  person being called; the far end is reached by the inline `<Dial>` TwiML that
  travels with the request. So a refusal here means nobody's phone rang, and
  there is deliberately no public endpoint for Twilio to call back into.

  What these cannot prove is that Twilio accepts the document — `Req.Test`
  answers instead of Twilio, so a live call is still the only thing that
  confirms the API contract. What they do prove is that we build the right
  request, and refuse the wrong ones before one is built.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Sentinel
  alias BusterClaw.Telephony

  @operator "+15033412655"
  @ours "+13603646763"

  setup do
    previous = Application.get_env(:buster_claw, :twilio)

    Application.put_env(:buster_claw, :twilio, %{
      account_sid: "AC_test",
      auth_token: "tok",
      phone_number: @ours,
      operator_number: @operator,
      voice_enabled: true
    })

    on_exit(fn -> Application.put_env(:buster_claw, :twilio, previous) end)
    Req.Test.verify_on_exit!()
    :ok
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [daily_cap: 2, req_options: [plug: {Req.Test, BusterClaw.CallHTTP}]],
      extra
    )
  end

  # A distinct sid per stub: `twilio_sid` is unique, so two accepted calls in one
  # test collide on the constraint rather than on anything being tested.
  defp accept(sid \\ "CA_local", assert_fun \\ fn _params -> :ok end) do
    Req.Test.expect(BusterClaw.CallHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert_fun.(URI.decode_query(body))
      Req.Test.json(conn, %{"sid" => sid, "status" => "queued"})
    end)
  end

  # config/runtime.exs does not run under MIX_ENV=test, so nothing else in this
  # suite can observe it — and for a day it was wrong in a way no behavioural test
  # could see: `voice_enabled` was read by Twilio but never written by runtime.exs,
  # so the switch read false no matter what the operator set, and every kill-switch
  # test passed anyway because they set the key directly.
  #
  # This reads the source and pairs the two sides. It is deliberately derived from
  # the reader rather than a hardcoded list, so the third switch is covered on the
  # day it is added and not the day someone remembers this file.
  describe "the kill switches are reachable from the environment" do
    test "every switch Twilio reads is one runtime.exs writes" do
      reader = File.read!("lib/buster_claw/telephony/twilio.ex")
      runtime = File.read!("config/runtime.exs")

      switches =
        Regex.scan(~r/get_in\(config\(\), \[:(\w+)\]\)/, reader, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert "sms_enabled" in switches
      assert "voice_enabled" in switches

      for switch <- switches do
        assert runtime =~ "#{switch}:",
               "Twilio reads :#{switch} from the :twilio config, but config/runtime.exs " <>
                 "never sets it — so it is false in every build and cannot be turned on."
      end
    end

    test "the switch map is not gated on a credential that may live in the Clinch" do
      runtime = File.read!("config/runtime.exs")

      refute runtime =~
               ~r/if System\.get_env\("TWILIO_ACCOUNT_SID"\) do\n\s+config :buster_claw, :twilio/,
             "Credentials are read through the Clinch with env as fallback, so gating " <>
               "the switch map on TWILIO_ACCOUNT_SID makes both switches unflippable " <>
               "for an operator who stored their credentials properly."
    end
  end

  describe "the request we build" do
    test "rings the OPERATOR first and carries the far end in inline TwiML" do
      accept("CA_local", fn params ->
        # The single most surprising line in this feature: To is the operator.
        assert params["To"] == @operator
        assert params["From"] == @ours

        # The far end travels in the document, not in a parameter, and there is
        # no Url — nothing calls back, so there is no endpoint to abuse.
        assert params["Twiml"] =~ "<Dial"
        assert params["Twiml"] =~ "+15035550123"
        refute Map.has_key?(params, "Url")

        # Both legs present the app's number: From is what the operator sees
        # ringing, callerId is what the far end sees.
        assert params["Twiml"] =~ ~s(callerId="#{@ours}")
      end)

      assert {:ok, result} = Telephony.place_call("(503) 555-0123", opts())
      assert result.placed
      assert result.to == "+15035550123"
      assert result.call_sid == "CA_local"
    end

    test "files the call locally and audits it as an outbound send" do
      accept()
      assert {:ok, _} = Telephony.place_call("+15035550123", opts())

      assert [event] = Telephony.list_events() |> Enum.filter(&(&1.kind == "call"))
      assert event.direction == "outbound"
      assert event.to_number == "+15035550123"
      assert event.twilio_sid == "CA_local"

      assert Enum.any?(Sentinel.list_events(), fn e ->
               e.category == "outbound_send" and e.message =~ "Call placed to +15035550123"
             end)
    end
  end

  describe "refusals — none of these place a call" do
    test "the voice switch is separate from the SMS one" do
      Application.put_env(:buster_claw, :twilio, %{
        account_sid: "AC_test",
        auth_token: "tok",
        phone_number: @ours,
        operator_number: @operator,
        # SMS on, voice off. A text is not a phone call.
        sms_enabled: true,
        voice_enabled: false
      })

      assert {:error, :voice_disabled} = Telephony.place_call("+15035550123", opts())
    end

    test "each missing precondition names itself" do
      for {config, expected} <- [
            {%{account_sid: "AC", auth_token: "t", operator_number: @operator},
             :missing_phone_number},
            {%{account_sid: "AC", auth_token: "t", phone_number: @ours},
             :missing_operator_number},
            {%{phone_number: @ours, operator_number: @operator}, :not_configured}
          ] do
        Application.put_env(:buster_claw, :twilio, Map.put(config, :voice_enabled, true))

        assert {:error, ^expected} = Telephony.place_call("+15035550123", opts())
      end
    end

    test "dialling our own number, or the operator's, is refused" do
      # Both would bridge the app to itself: two billed legs, a voicemail from
      # the operator to themselves, and something that looks exactly like a bug.
      assert {:error, :cannot_dial_own_number} = Telephony.place_call(@ours, opts())
      assert {:error, :cannot_dial_yourself} = Telephony.place_call(@operator, opts())
    end

    test "a number that replied STOP to a text cannot be phoned either" do
      # Voice has no STOP of its own. The roadmap named the choice: the SMS
      # opt-out list covers the same human, because treating a STOP as SMS-only
      # would mean a number that asked to be left alone can still be rung.
      {:ok, _} =
        Telephony.record_event(
          %{
            direction: "inbound",
            kind: "sms",
            from_number: "+15035550123",
            to_number: @ours,
            body: "STOP",
            occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          observe: false
        )

      assert {:error, :recipient_opted_out} = Telephony.place_call("+15035550123", opts())
    end

    test "the daily cap is per recipient and lower than the SMS one" do
      accept("CA_first")
      assert {:ok, _} = Telephony.place_call("+15035550123", opts(daily_cap: 1))

      assert {:error, {:call_daily_cap_reached, 1}} =
               Telephony.place_call("+15035550123", opts(daily_cap: 1))

      # …and it is per recipient, so a different number still goes through.
      accept("CA_second")
      assert {:ok, _} = Telephony.place_call("+15035550124", opts(daily_cap: 1))
    end

    test "an unparseable number never reaches Twilio" do
      assert {:error, :invalid_recipient} = Telephony.place_call("not a phone", opts())
    end
  end

  describe "the command surface" do
    test "phone_call is gated, so an untrusted run is refused without confirming" do
      # The whole reason this verb is gated rather than merely restricted:
      # PolicyEngine's baseline stops an :agent_untrusted caller ONLY with
      # gated: true. An unattended run triaging email it did not choose to read
      # must not be able to dial a stranger from the operator's number.
      assert {:error, :requires_confirmation} =
               BusterClaw.Commands.call("phone_call", %{"to" => "+15035550123"},
                 caller: :agent_untrusted
               )

      assert Telephony.list_events() |> Enum.filter(&(&1.kind == "call")) == []
    end

    test "a missing recipient is refused before anything is configured" do
      assert {:error, :missing_recipient} = BusterClaw.Commands.Telephony.phone_call(%{})
    end
  end
end
