defmodule BusterClaw.Commands.Catalog.Telephony do
  @moduledoc """
  Catalog entries: BusterPhone (the Message Machine).

  Reads are `:safe` — an untrusted caller-provenance run may still *look* at the
  phone log, which is how it triages a voicemail it was queued for. Anything that
  mutates is `:restricted`, and the trusted-numbers list is `gated` on top of that:
  adding a number decides who may drive agent work, so it is exactly as
  consequential as a send, and an untrusted run must never be able to promote its
  own caller into the trusted list.
  """

  @doc "Telephony catalog entries."
  def entries,
    do: [
      %{
        name: "phone_list",
        type: :read,
        tier: :safe,
        description:
          "List phone events (voicemails, calls) newest first. Optional kind (voicemail|sms|call), unheard_only, limit.",
        args: %{
          "kind" => %{type: :string, required: false},
          "unheard_only" => %{type: :boolean, required: false},
          "limit" => %{type: :integer, required: false, default: 25}
        }
      },
      %{
        name: "phone_get",
        type: :read,
        tier: :safe,
        description:
          "One phone event by id, with its transcript and recording path. Does not mark it heard.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "phone_stats",
        type: :read,
        tier: :safe,
        description: "Message Machine counts: total events, unheard voicemails, by kind.",
        args: %{}
      },
      %{
        name: "phone_mark_heard",
        type: :mutate,
        tier: :restricted,
        description:
          "Mark a phone event as heard (clears the answering machine's blinking light).",
        args: %{"id" => %{type: :integer, required: true}}
      },
      # :restricted, not :safe — this is a *policy* read, not operational data.
      # Caller ID is trivially spoofable, so handing an untrusted-provenance run the
      # allowlist hands it exactly the number to spoof to get its voicemail queued.
      # A voicemail-triage agent never needs it (its item is already queued), and
      # the email twin isn't on the command surface at all — so safe-tier here would
      # be strictly more permissive than the pattern it mirrors.
      %{
        name: "phone_trusted_list",
        type: :read,
        tier: :restricted,
        description:
          "The trusted-caller list (E.164). Only these callers' voicemail reaches the Dispatch queue.",
        args: %{}
      },
      %{
        name: "phone_trusted_add",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Trust a caller: their voicemail becomes agent work. Gated — this decides who may drive the queue.",
        args: %{"number" => %{type: :string, required: true}}
      },
      %{
        name: "phone_trusted_remove",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Stop trusting a caller. Their voicemail is still recorded, but never queued.",
        args: %{"number" => %{type: :string, required: true}}
      },
      # Caller-PIN management is the second factor behind the trusted-numbers list:
      # a voicemail is only agent work when the number is trusted AND the call was
      # PIN-verified. Setting a PIN decides who can satisfy that gate, so it is
      # exactly as consequential as trusting a number — :restricted and gated, so
      # an untrusted-provenance run can never mint itself a credential.
      %{
        name: "phone_pin_set",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Set a caller's PIN (4–10 digits). With a PIN, a trusted caller who punches it becomes agent work. Gated — this mints a credential.",
        args: %{
          "number" => %{type: :string, required: true},
          "pin" => %{type: :string, required: true}
        }
      },
      %{
        name: "phone_pin_remove",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Remove a caller's PIN. Their calls can no longer PIN-verify, so their voicemail stops reaching the queue.",
        args: %{"number" => %{type: :string, required: true}}
      },
      # :restricted, not :safe — like phone_trusted_list, this is policy data. It
      # never returns pin_hash or salt, but the set of numbers that HAVE a PIN, and
      # their failed-attempt counts, is exactly the recon an attacker wants; a
      # voicemail-triage run has no need for it.
      %{
        name: "phone_pin_list",
        type: :read,
        tier: :restricted,
        description:
          "Configured caller PINs as policy telemetry: number, failed attempts, last verified. Never returns the hash.",
        args: %{}
      }
    ]
end
