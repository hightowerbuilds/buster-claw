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

  sms_thread = [
    {"inbound", "Hey, is the workbench still for sale?", 5 * 3600},
    {"outbound", "It is — $120, pickup in Sellwood. Evenings work best.", 5 * 3600 - 240},
    {"inbound", "Great. Would 6:30 tomorrow work?", 4 * 3600},
    {"outbound", "6:30 works. I'll text the address in the morning.", 4 * 3600 - 120}
  ]

  sms_thread
  |> Enum.with_index(1)
  |> Enum.each(fn {{direction, body, seconds_ago}, index} ->
    {from, to} =
      case direction do
        "inbound" -> {"+15035550177", "+18446878016"}
        "outbound" -> {"+18446878016", "+15035550177"}
      end

    {:ok, _} =
      Telephony.record_event(
        %{
          direction: direction,
          kind: "sms",
          from_number: from,
          to_number: to,
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
        twilio_sid: "DEMO-sms-5",
        occurred_at: TelephonyDemo.ago(30 * 3600),
        metadata: %{"demo" => true}
      },
      observe: false
    )

  IO.puts("Seeded telephony demo data: 2 voicemails (1 unheard), 1 missed call, 5 texts.")
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
