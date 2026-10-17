defmodule BusterClaw.Commands.Catalog.Sound do
  @moduledoc """
  Catalog entries: the notification sound library and its routing table.

  The reads are `:safe`: they open files read-only, touch no setting, and change
  nothing about what the machine plays. `sound_apply` is `gated` because it
  changes outbound behaviour — it points a routing key at a sound, the only
  entry here that changes what the machine *does* when nobody is watching.
  `sound_restore_defaults` is its counterweight: `:restricted` but not gated,
  because it is the way back and gating an undo only ever strands the person
  using it.

  > The Sound Studio's eleven verbs — `sound_sources`, `sound_import`, the four
  > editing verbs, `sound_delete` and the four microphone verbs — were deleted
  > with the Studio on 10-16 (`STUDIO_REMOVAL_ROADMAP`). The cut-up's eighteen
  > left on 09-19 with the engine under them. A stale entry would teach a model
  > a command that answers `unknown_command`.
  """

  @doc "Sound catalog entries."
  def entries,
    do: [
      %{
        name: "sound_list",
        type: :read,
        tier: :safe,
        description:
          "The notification sound library across BOTH layers: bundled defaults and workspace files in sounds/, which layer each name resolves from, and which bundled defaults a workspace file is shadowing. Read this before describing or proposing any change to a sound.",
        args: %{}
      },
      %{
        name: "sound_routes",
        type: :read,
        tier: :safe,
        description:
          "The event-to-sound routing table: every routing key (sources like email, kinds like timer, and default), its human label, what is explicitly assigned, and what actually plays after inheritance — including keys that are silent or play nothing. The map to read before suggesting a routing change.",
        args: %{}
      },
      %{
        name: "sound_probe",
        type: :read,
        tier: :safe,
        description:
          "Inspect one sound's header: duration_ms, sample_rate and channels, read by the system prober without decoding it. The only way to learn what a sound is without listening to it. Name it two ways: name (a workspace library file, then a bundled default), or path (relative to the Library root — absolute paths and .. are refused).",
        args: %{
          "name" => %{type: :string, required: false},
          "path" => %{type: :string, required: false}
        }
      },
      %{
        name: "sound_apply",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Route a notification key to a sound from the library — the one verb that changes what the machine does when nobody is watching. source is a library name (a workspace file in sounds/, or a bundled default) and route must be a key from sound_routes (default, timer, alarm, reminder, chat, terminal, email, manual, confirm, shift, blocked, web, order, security, boot); anything else is refused as unknown_route BEFORE anything changes, so a typo can never be discovered later as a chime that does not play. Reports what the key played before, so the change can be undone with sound_apply or sound_restore_defaults. Tell the operator what you are about to route before routing it.",
        args: %{
          "source" => %{type: :string, required: true},
          "route" => %{type: :string, required: true}
        }
      },
      %{
        name: "sound_restore_defaults",
        type: :mutate,
        tier: :restricted,
        description:
          "Put the shipped sound defaults back — the way out of a routing or overwrite you regret. Copies the bundled chimes into sounds/ and NEVER overwrites: a name already there is skipped, because that file is the operator's edit or replacement. Files only by default; pass routes true to also clear every routing assignment so each key inherits again and falls back to its bundled chime. Nothing is ever deleted. Reports what was copied, what was skipped, and which keys were cleared.",
        args: %{
          "sounds" => %{type: :boolean, required: false, default: true},
          "routes" => %{type: :boolean, required: false, default: false}
        }
      }
    ]
end
