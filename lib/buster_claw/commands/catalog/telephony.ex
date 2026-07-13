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
      }
    ]
end
