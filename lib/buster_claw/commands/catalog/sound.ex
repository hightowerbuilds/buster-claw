defmodule BusterClaw.Commands.Catalog.Sound do
  @moduledoc """
  Catalog entries: the sound library, its routing table, the Sound Studio's
  imported clips and the edits made to them, and audio capture.

  The cut-up surface — transcripts, the word index, `sound_align`, `sound_find`,
  `sound_sentence`, `sound_assemble`, `sound_gaps`, `sound_record_save` and the
  `voice_bank_*` verbs, eighteen entries — was deleted 09-19 with the engine under
  it (`CUTUP_DELETION_ROADMAP`).

  The reads are `:safe`: they open files read-only, touch no setting, and change
  nothing about what the machine plays.

  Everything that writes is `:restricted`. The line is worth stating:
  `sound_import` and the four editing verbs write a **new source** into
  `sounds/studio/`, and `sound_delete` removes one. None of those installs a
  chime, routes a key, or opens a microphone.

  **Two entries are `gated`, for two different reasons, and the reasons do not
  substitute for each other:**

  * **`sound_apply` gates a change in outbound behaviour.** It copies a studio
    source into the sound library and points a routing key at it — the only entry
    here that changes what the machine *does* when nobody is watching.
    `sound_restore_defaults` is its counterweight: `:restricted` but not gated,
    because it is the way back and gating an undo only ever strands the person
    using it.
  * **`sound_record` gates hardware capture.** It opens the **microphone**. That
    is not a behaviour change — nothing plays differently afterwards — it is a
    privacy boundary, and `PolicyEngine`'s baseline is what forces the flag:
    `:restricted` earns a confirmation from an `:agent` or `:mcp` caller, but an
    **`:agent_untrusted` caller is stopped only by `gated`**. Ungated, an
    unattended run acting on content it did not choose could have recorded the
    room. See `Commands.SoundCapture` for the argument in full.

  **Do not restore a superlative here.** This paragraph read *"exactly one of
  them is gated"* and named `sound_apply` as *"the only entry"* until 08-09, when
  `sound_record` landed and made both claims false — and worse, made the
  behaviour-change sentence look like the reason the microphone verb was gated.
  A count of gated verbs in this family is a fact about three sessions' work in
  flight, not an invariant; state the *reasons*, which are stable, rather than
  the tally, which is not. Found by a neighbouring session whose test asserted the
  superlative and passed against `HEAD` while failing against the merged tree.

  `sound_import` is the one entry that names a file **outside** the sound
  stores, and its two inputs are the whole of that reach: an `event_id`, whose
  recording path the app itself stored, or a path **relative to the Library
  root**. Absolute paths and `..` are refused, so the verb can address the
  operator's recordings and nothing else on the disk.
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
          "The event-to-sound routing table: every routing key (sources like voicemail, kinds like timer, and default), its human label, what is explicitly assigned, and what actually plays after inheritance — including keys that are silent or play nothing. The map to read before suggesting a routing change.",
        args: %{}
      },
      %{
        name: "sound_sources",
        type: :read,
        tier: :safe,
        description:
          "The Sound Studio's imported clips in sounds/studio/ — raw working material being edited, not the routed library that sound_list reports. Also reports whether the system audio decoder is present, which is what decides if non-WAV audio can be imported at all.",
        args: %{}
      },
      %{
        name: "sound_probe",
        type: :read,
        tier: :safe,
        description:
          "Inspect one sound: sample rate, channels, bits, duration_ms, peak level, and whether it is already in the Studio's internal PCM16 mono 22.05 kHz format. The only way to learn what a sound actually is without listening to it. Name it three ways: name (a workspace library file, then a bundled default, then a studio source), event_id (a phone event's recording), or path (relative to the Library root — absolute paths and .. are refused). Peak needs decoded samples, so an mp3 or m4a reports none by default; decode true measures it by running the file through the decoder, which is exact and costs a full decode.",
        args: %{
          "name" => %{type: :string, required: false},
          "event_id" => %{type: :integer, required: false},
          "path" => %{type: :string, required: false},
          "decode" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_import",
        type: :mutate,
        tier: :restricted,
        description:
          "Bring an audio file into sounds/studio/ as a WAV in the Studio's internal format — the door a voicemail comes through before anything can cut it up. Name the file with event_id (a phone event, whose recording is imported) or path (relative to the Library root; absolute paths and .. are refused). name is the stored basename and is always forced to .wav; omit it to derive one from the source. Refuses an existing source unless overwrite is true. Reports duration, peak, format and whether the system decoder had to run — non-WAV audio on a machine without /usr/bin/afconvert is refused as no_decoder rather than failing later.",
        args: %{
          "event_id" => %{type: :integer, required: false},
          "path" => %{type: :string, required: false},
          "name" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_trim",
        type: :mutate,
        tier: :restricted,
        description:
          "Cut a span out of one studio source and write it as a NEW source: start_ms (default 0) to end_ms (default the end of the clip), so trimming leading silence or a tail is one argument. Values outside the clip clamp to it; a span that ends at or before it starts is refused as empty_selection rather than written as a zero-length file. Omit name and the result is named after its input (harbor.wav becomes harbor-trim.wav); an existing name is refused unless overwrite is true. Reports the new duration_ms and peak beside the source's own, which is how you check a trim removed what you meant without listening.",
        args: %{
          "source" => %{type: :string, required: true},
          "start_ms" => %{type: :number, required: false, default: 0},
          "end_ms" => %{type: :number, required: false},
          "name" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_fade",
        type: :mutate,
        tier: :restricted,
        description:
          "Fade one studio source in and/or out, writing a NEW source. The ramps land on true zero at the first and last sample, which is the fix for the click a clip cut from the middle of a recording starts with — a step from silence to full amplitude. At least one of in_ms or out_ms is required, because a fade with neither would write a byte-identical copy under a new name. Ramps longer than the clip are clamped. Omit name and the result is named after its input; an existing name is refused unless overwrite is true.",
        args: %{
          "source" => %{type: :string, required: true},
          "in_ms" => %{type: :number, required: false},
          "out_ms" => %{type: :number, required: false},
          "name" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_normalize",
        type: :mutate,
        tier: :restricted,
        description:
          "Scale one studio source so its loudest sample sits at target (0 to 1, default about 0.891 — roughly -1 dBFS), writing a NEW source. This is peak normalization, not loudness: it makes a quiet clip usable and cannot make a clipped one clean. Compare peak against source_peak in the result to see what it did — a source already near 1.0 barely moves, and digital silence is returned untouched because no gain makes zero louder. Omit name and the result is named after its input; an existing name is refused unless overwrite is true.",
        args: %{
          "source" => %{type: :string, required: true},
          "target" => %{type: :number, required: false, default: 0.891},
          "name" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_concat",
        type: :mutate,
        tier: :restricted,
        description:
          "Join whole studio sources end to end, in the order given, as one NEW source. Every source must share a format — joining a 44.1 kHz clip onto a 22.05 kHz one would play the first at half speed, so a mismatch is refused as format_mismatch rather than resampled. Naming the same source twice joins it twice, on purpose. This is a bare join: no padding, no fade, no gap, so every seam is a hard cut. Fade each piece first with sound_fade if the seams click. An existing name is refused unless overwrite is true.",
        args: %{
          "sources" => %{type: :list, required: true},
          "name" => %{type: :string, required: true},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_delete",
        type: :mutate,
        tier: :restricted,
        description:
          "Delete one studio source from sounds/studio/. Only the studio's working material — the sound library and the routing table are untouched, and this cannot remove a chime that is currently playing for something. Irreversible: an imported voicemail can be imported again, but an edit rendered from it cannot.",
        args: %{
          "name" => %{type: :string, required: true}
        }
      },
      %{
        name: "sound_apply",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Install a studio source into the sound library and route a notification key to it — the last step, and the only one that changes what the machine does when nobody is watching. route must be a key from sound_routes (default, timer, alarm, reminder, chat, terminal, email, voicemail, manual, confirm, shift, blocked, web, order, sms, security, boot); anything else is refused as unknown_route BEFORE the file is written, so a typo can never be discovered later as a chime that does not play. name is the library basename (default the source's own, always .wav). Refuses name_taken if that name is already in the library, and shadows_bundled if it matches a bundled default — that second case would replace the built-in chime for EVERY key falling back to it, not just this one — unless overwrite is true. Reports what the key played before, so the change can be undone. Tell the operator what you are about to route before routing it.",
        args: %{
          "source" => %{type: :string, required: true},
          "route" => %{type: :string, required: true},
          "name" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
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
      },
      %{
        name: "sound_devices",
        type: :read,
        tier: :safe,
        description:
          "Audio input devices that could be recorded from, with name, transport (builtin, usb, bluetooth, virtual, unknown), channels, sample_rate_hz, and which is the system default. Read from system_profiler, not ffmpeg — ffmpeg's device list gives a name and nothing else. TWO CAVEATS THAT MATTER: sample_rate_hz is the device's ADVERTISED capability, not what an open stream will actually run at, so never quote it as the rate of a recording. And a Bluetooth headset opened as an INPUT drops from A2DP to HFP, which is 8 kHz narrowband, phone-quality audio — so a recording made over one is close to worthless. Bluetooth-LE devices may report transport unknown rather than bluetooth, so treat unknown as unproven rather than safe.",
        args: %{}
      },
      %{
        name: "sound_input_level",
        type: :read,
        tier: :safe,
        description:
          "The OS input volume of the current default input device, 0 to 100. Coarse, and it is the hardware input level rather than anything applied after capture. Errors with no_input_device when the machine has no controllable input — which is NOT the same as a volume of 0, and must never be rendered as one, because on a slider they look identical and mean opposite things.",
        args: %{}
      },
      %{
        name: "sound_input_level_set",
        type: :mutate,
        tier: :restricted,
        description:
          "Set the OS input volume of the current default input device, 0 to 100. Reports previous so the change can be undone. Coarse, applies to the default input rather than a named device, and cannot be aimed at one. This is the real hardware input level — which matters because a gain applied AFTER capture raises the recorded level but cannot undo clipping that already happened at the converter. Aim for peaks around -12 to -6 dBFS while speaking, with nothing touching 0: digital clipping is unrecoverable and no later verb repairs it.",
        args: %{
          "volume" => %{type: :integer, required: true}
        }
      },
      %{
        name: "sound_record",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Record from an input device into sounds/studio/ as a new source — duration-bounded (seconds, up to 300), optional name and device, default input when device is omitted. Gated because it opens the MICROPHONE, and an unattended run acting on content it did not choose must not do that without a person saying yes. READ THIS BEFORE RELYING ON IT: on macOS this path can return perfect digital SILENCE with a zero exit code and nothing on stderr, because microphone consent is granted to the responsible process and the chain here is the BEAM spawning ffmpeg, which carries neither an Info.plist nor an entitlement of its own. Measured 08-09: a real capture produced a valid WAV whose every sample was zero, and no consent prompt ever appeared. So the result is read back and a silent take is REFUSED rather than stored, returning silent_capture with the reason. Reports peak and clipped so a bad take is caught at the door. A name collision de-duplicates rather than overwriting, because the capture already happened and cannot be retaken. This is a convenience for a trusted caller. Existing recordings can also enter the sound library through sound_import without opening the microphone.",
        args: %{
          "seconds" => %{type: :number, required: true},
          "name" => %{type: :string, required: false},
          "device" => %{type: :string, required: false}
        }
      }
    ]
end
