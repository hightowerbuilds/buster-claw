# Demo traffic for the Message Machine panel, so the UI is browsable before the
# Twilio number is live: playable voicemails synthesized with macOS `say`, an
# SMS thread, and a missed call. Safe to re-run (skips if demo rows exist).
#
#   mix run priv/repo/seeds/telephony_demo.exs

import Ecto.Query

alias BusterClaw.Library.Artifact
alias BusterClaw.LocalTime
alias BusterClaw.Repo
alias BusterClaw.Telephony
alias BusterClaw.Contacts
alias BusterClaw.Contacts.Contact
alias BusterClaw.Telephony.Event

defmodule TelephonyDemo do
  def synthesize_voicemail(filename, voice, text) do
    dir = Artifact.raw_date_dir(LocalTime.today())
    File.mkdir_p!(dir)
    aiff = Path.join(System.tmp_dir!(), "#{filename}.aiff")
    m4a = Path.join(dir, "#{filename}.m4a")

    {_, 0} = System.cmd("say", ["-v", voice, "-o", aiff, text])
    {_, 0} = System.cmd("afconvert", ["-f", "m4af", "-d", "aac", aiff, m4a])
    File.rm(aiff)

    {Path.relative_to(m4a, Artifact.root()), duration_of(m4a)}
  end

  defp duration_of(path) do
    with {out, 0} <- System.cmd("afinfo", [path]),
         [_, seconds] <- Regex.run(~r/estimated duration:\s+([\d.]+)/i, out),
         {value, _rest} <- Float.parse(seconds) do
      round(value)
    else
      _ -> nil
    end
  end

  def ago(seconds) do
    DateTime.utc_now(:second) |> DateTime.add(-seconds)
  end
end

if Repo.exists?(from e in Event, where: like(e.twilio_sid, "DEMO%")) do
  IO.puts("Telephony demo data already present — nothing to do.")
else
  {vm1_path, vm1_duration} =
    TelephonyDemo.synthesize_voicemail(
      "voicemail-demo-1",
      "Samantha",
      "Hey, it's Dana from the print shop. Your poster order is ready for pickup " <>
        "any time before six. We're closed Sunday. See you soon, bye."
    )

  {vm2_path, vm2_duration} =
    TelephonyDemo.synthesize_voicemail(
      "voicemail-demo-2",
      "Daniel",
      "Good afternoon, this is Marcus calling about the workbench you listed. " <>
        "I can come by Saturday morning with cash if it's still available. " <>
        "Call me back at this number. Thanks."
    )

  {:ok, _} =
    Telephony.record_event(
      %{
        direction: "inbound",
        kind: "voicemail",
        from_number: "+15035550142",
        to_number: "+18446878016",
        duration_seconds: vm1_duration,
        recording_path: vm1_path,
        transcript:
          "Hey, it's Dana from the print shop. Your poster order is ready for pickup " <>
            "any time before six. We're closed Sunday. See you soon, bye.",
        twilio_sid: "DEMO-vm-1",
        occurred_at: TelephonyDemo.ago(2 * 3600),
        metadata: %{"demo" => true}
      },
      observe: false
    )

  {:ok, _} =
    Telephony.record_event(
      %{
        direction: "inbound",
        kind: "voicemail",
        from_number: "+15035550177",
        to_number: "+18446878016",
        duration_seconds: vm2_duration,
        recording_path: vm2_path,
        transcript:
          "Good afternoon, this is Marcus calling about the workbench you listed. " <>
            "I can come by Saturday morning with cash if it's still available. " <>
            "Call me back at this number. Thanks.",
        twilio_sid: "DEMO-vm-2",
        occurred_at: TelephonyDemo.ago(26 * 3600),
        heard_at: TelephonyDemo.ago(20 * 3600),
        metadata: %{"demo" => true}
      },
      observe: false
    )

  {:ok, _} =
    Telephony.record_event(
      %{
        direction: "inbound",
        kind: "call",
        from_number: "+12065550190",
        to_number: "+18446878016",
        twilio_sid: "DEMO-call-1",
        occurred_at: TelephonyDemo.ago(3 * 24 * 3600),
        metadata: %{"demo" => true}
      },
      observe: false
    )

  # Inbound only, and deliberately so. This thread used to alternate
  # inbound/outbound — the agent answering "$120, pickup in Sellwood" — which
  # demonstrated a capability the phone no longer has (PHONE_INTAKE_ROADMAP,
  # 08-18: outbound SMS deleted). Real `direction: "outbound"` rows that predate
  # that cut stay in the database, because they are a true record of something
  # that happened; a *seed* that manufactures them is not a record, it is an
  # advertisement for a deleted feature, rendered on the /phone tab to anyone
  # who runs the demo.
  #
  # An unanswered thread is also the more honest demo: this is what intake
  # actually looks like, and the second message arriving because the first got
  # no reply is the texture a two-way thread hid.
  sms_thread = [
    {"Hey, is the workbench still for sale?", 5 * 3600},
    {"Still interested if it is — I can pick up evenings.", 4 * 3600},
    {"No rush, just let me know either way.", 3 * 3600}
  ]

  sms_thread
  |> Enum.with_index(1)
  |> Enum.each(fn {{body, seconds_ago}, index} ->
    {:ok, _} =
      Telephony.record_event(
        %{
          direction: "inbound",
          kind: "sms",
          from_number: "+15035550177",
          to_number: "+18446878016",
          body: body,
          twilio_sid: "DEMO-sms-#{index}",
          occurred_at: TelephonyDemo.ago(seconds_ago),
          metadata: %{"demo" => true}
        },
        observe: false
      )
  end)

  {:ok, _} =
    Telephony.record_event(
      %{
        direction: "inbound",
        kind: "sms",
        from_number: "+19715550163",
        to_number: "+18446878016",
        body: "Your package was delivered to the front porch.",
        twilio_sid: "DEMO-sms-4",
        occurred_at: TelephonyDemo.ago(30 * 3600),
        metadata: %{"demo" => true}
      },
      observe: false
    )

  IO.puts("Seeded telephony demo data: 2 voicemails (1 unheard), 1 missed call, 4 inbound texts.")
end

# Contacts seed separately so re-runs after the events exist still add them.
if Repo.exists?(from c in Contact, limit: 1) do
  IO.puts("Telephony contacts already present — nothing to do.")
else
  # Contacts only — never trust. Seeding a trusted contact would write a live
  # entry into the markdown policy file that gates the agent's work queue, and a
  # demo fixture has no business touching the security policy.
  {:ok, _} =
    Contacts.create_contact(%{
      name: "Dana (Print Shop)",
      phone: "+15035550142",
      email: "dana@printshop.example"
    })

  {:ok, _} = Contacts.create_contact(%{name: "Marcus", phone: "+15035550177"})
  {:ok, _} = Contacts.create_contact(%{name: "Porch Pirate Watch", phone: "+19715550163"})
  IO.puts("Seeded 3 demo contacts.")
end
