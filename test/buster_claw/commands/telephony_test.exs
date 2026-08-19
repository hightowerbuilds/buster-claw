defmodule BusterClaw.Commands.TelephonyTest do
  # async: false — the trusted-numbers policy is workspace-global.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Telephony

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "memory"))

    on_exit(fn -> Application.put_env(:buster_claw, :workspace_root, prev_ws) end)
    :ok
  end

  defp voicemail(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          direction: "inbound",
          kind: "voicemail",
          from_number: "+15035551234",
          to_number: "+18446878016",
          transcript: "Hey, call me back.",
          duration_seconds: 12,
          twilio_sid: "RE#{System.unique_integer([:positive])}",
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        overrides
      )

    {:ok, event} = Telephony.record_event(attrs, observe: false)
    event
  end

  describe "phone_list" do
    test "lists newest first and reports whether the caller is trusted" do
      _old = voicemail(%{transcript: "older"})
      new = voicemail(%{transcript: "newer", from_number: "+15039999999"})

      assert {:ok, [first | _] = all} = Commands.call("phone_list", %{}, caller: :trusted)
      assert length(all) == 2
      assert first.id == new.id
      # Nobody is on the trusted list, so no caller may drive work.
      refute first.trusted_caller
    end

    test "unheard_only returns only unheard voicemail" do
      heard = voicemail()
      {:ok, _} = Telephony.mark_heard(heard)
      unheard = voicemail()

      assert {:ok, [only]} =
               Commands.call("phone_list", %{"unheard_only" => true}, caller: :trusted)

      assert only.id == unheard.id
    end

    test "rejects an unknown kind rather than silently returning everything" do
      voicemail()

      assert {:error, :invalid_kind} =
               Commands.call("phone_list", %{"kind" => "telegram"}, caller: :trusted)
    end
  end

  describe "phone_get" do
    test "returns the transcript and recording path" do
      event = voicemail(%{recording_path: "phone/recordings/x.mp3"})

      assert {:ok, detail} = Commands.call("phone_get", %{"id" => event.id}, caller: :trusted)
      assert detail.transcript == "Hey, call me back."
      assert detail.recording_path == "phone/recordings/x.mp3"
    end

    test "reading does not mark the voicemail heard" do
      event = voicemail()

      assert {:ok, detail} = Commands.call("phone_get", %{"id" => event.id}, caller: :trusted)
      refute detail.heard
      # The blinking light is the operator's — an agent skimming the log must not
      # clear it behind their back.
      refute Telephony.get_event(event.id).heard_at
      assert Telephony.unheard_count() == 1
    end

    test "a bad id is not_found, not a crash" do
      assert {:error, :not_found} =
               Commands.call("phone_get", %{"id" => 999_999}, caller: :trusted)
    end
  end

  describe "phone_mark_heard" do
    test "clears the blinking light" do
      event = voicemail()
      assert Telephony.unheard_count() == 1

      assert {:ok, summary} =
               Commands.call("phone_mark_heard", %{"id" => event.id}, caller: :trusted)

      assert summary.heard
      assert Telephony.unheard_count() == 0
    end
  end

  describe "trust tiers" do
    test "reads are safe — an untrusted-provenance run may still triage its voicemail" do
      event = voicemail()

      assert {:ok, _} = Commands.call("phone_list", %{}, caller: :agent)
      assert {:ok, _} = Commands.call("phone_get", %{"id" => event.id}, caller: :agent)
      assert {:ok, _} = Commands.call("phone_stats", %{}, caller: :agent)
    end

    test "a safe-tier caller cannot mark heard (it mutates)" do
      event = voicemail()

      assert {:error, :requires_confirmation} =
               Commands.call("phone_mark_heard", %{"id" => event.id}, caller: :agent)
    end

    test "an untrusted run cannot promote its own caller into the trusted list" do
      # This is the whole point of gating phone_trusted_add: a run that has touched
      # untrusted content must never be able to grant a caller the right to drive
      # future work.
      assert {:error, :requires_confirmation} =
               Commands.call("phone_trusted_add", %{"number" => "+15035551234"},
                 caller: :agent_untrusted
               )

      assert {:error, :requires_confirmation} =
               Commands.call("phone_trusted_remove", %{"number" => "+15035551234"},
                 caller: :agent_untrusted
               )

      assert BusterClaw.TrustedNumbers.list_entries() == []
    end

    # This replaces "an untrusted run cannot send SMS", which asked whether the
    # gate held. BusterPhone became intake-only on 08-18
    # (PHONE_INTAKE_ROADMAP), and the honest successor question is whether there
    # is anything left to gate — a deleted capability cannot be gated wrongly,
    # socially engineered, or described falsely.
    #
    # Deleting the old test and stopping there is how outbound comes back
    # unnoticed: nothing else in this file would notice a new send verb. So the
    # assertion inverts rather than disappears. If either name returns, this
    # fails, and whoever re-added it has to state the product argument (Part I:
    # outbound voice was never blocked by paperwork, so paperwork clearing is
    # not a reason).
    test "the phone surface only receives — there is no outbound verb to gate" do
      assert Commands.command_type("sms_send") == nil
      assert Commands.command_type("phone_call") == nil

      # Not merely absent from the catalog: unreachable through the front door,
      # including via a composition skill that might claim the name.
      assert {:error, :unknown_command} =
               Commands.call(
                 "sms_send",
                 %{"to" => "+15035550123", "body" => "Do not send"},
                 caller: :trusted
               )

      assert {:error, :unknown_command} =
               Commands.call("phone_call", %{"to" => "+15035550123"}, caller: :trusted)
    end
  end

  describe "phone_trusted_add / _list / _remove" do
    test "a trusted caller round-trips through the command surface" do
      assert {:ok, "+18446878016"} =
               Commands.call("phone_trusted_add", %{"number" => "(844) 687-8016"},
                 caller: :trusted
               )

      assert {:ok, ["+18446878016"]} =
               Commands.call("phone_trusted_list", %{}, caller: :trusted)

      assert {:ok, :removed} =
               Commands.call("phone_trusted_remove", %{"number" => "844-687-8016"},
                 caller: :trusted
               )

      assert {:ok, []} = Commands.call("phone_trusted_list", %{}, caller: :trusted)
    end

    test "an unparseable number is refused" do
      assert {:error, :invalid_entry} =
               Commands.call("phone_trusted_add", %{"number" => "nope"}, caller: :trusted)
    end
  end
end
