defmodule BusterClaw.Commands.Catalog.Sound do
  @moduledoc """
  Catalog entries: the sound library, its routing table, the Sound Studio's
  imported clips, and the cut-up surface — searching recordings for words and
  splicing them into new sources (STUDIO_ROADMAP Part I Phases 0/1, Part III
  Phases A/B).

  The reads are `:safe`: they open files read-only, touch no setting, and change
  nothing about what the machine plays.

  Everything that writes is `:restricted`. The line is worth stating:
  `sound_import`, `sound_assemble` and the four editing verbs write a **new
  source** into `sounds/studio/`, `sound_align` and `sound_index_*` write text
  beside it, and `sound_delete` removes one. None of those installs a chime,
  routes a key, or opens a microphone.

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

  `sound_find` and `sound_sentence` are the two entries whose descriptions carry
  a **measurement** rather than a default. `sound_find`'s threshold has no
  natural scale — the number that works was measured over 990 labelled pairs of
  real speech and sits an order of magnitude above what the synthetic tests
  suggested — and its cost is 109 s per uncached source, so a model choosing it
  has to be told both before it runs. `sound_sentence`'s description leads with
  the words it could not find and with `candidates` against `slots`, because
  those are the two ways its output can be wrong while looking right.

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
        name: "sound_transcript_search",
        type: :read,
        tier: :safe,
        description:
          "Find which recordings SAY a word or phrase, from the transcripts voicemails already carry. Returns an excerpt per hit and where the audio lives — but NO timings, so this is discovery, not cutting. Whole-word by default; with_recording (default true) keeps only hits whose audio is on disk. An empty result is weak evidence: the transcriber mangles telephony audio.",
        args: %{
          "query" => %{type: :string, required: true},
          "kind" => %{type: :string, required: false, default: "voicemail"},
          "with_recording" => %{type: :boolean, required: false, default: true},
          "whole_word" => %{type: :boolean, required: false, default: true},
          "since" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false, default: 50}
        }
      },
      %{
        name: "sound_transcript_words",
        type: :read,
        tier: :safe,
        description:
          "The most common words across the transcript corpus, with occurrence counts — the cheap viability check before planning a cut-up, since a word you have once is a word you cannot really use. Counts are a floor, not a census. These words have no timings and are not cuttable on their own; see sound_index_words for the ones that are.",
        args: %{
          "kind" => %{type: :string, required: false, default: "voicemail"},
          "with_recording" => %{type: :boolean, required: false, default: true},
          "min_count" => %{type: :integer, required: false, default: 1},
          "since" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false, default: 40}
        }
      },
      %{
        name: "sound_corpus",
        type: :read,
        tier: :safe,
        description:
          "How much recorded material exists at all: events, how many carry a transcript, how many name a recording, how many of those files are actually on disk (missing_audio is the gap), total duration, and word counts. Run this FIRST when transcript search comes back empty — recordings_on_disk of 0 means the audio lives in another workspace, not that the search is broken.",
        args: %{
          "kind" => %{type: :string, required: false, default: "voicemail"},
          "since" => %{type: :string, required: false}
        }
      },
      %{
        name: "sound_index_list",
        type: :read,
        tier: :safe,
        description:
          "Which studio sources have a word index — the per-source list of words WITH start/end times that cutting requires — plus each index's word count, origin (manual, recognizer, imported), and whether its audio is still present. A source with no index cannot be cut from, however good its transcript is.",
        args: %{}
      },
      %{
        name: "sound_index_words",
        type: :read,
        tier: :safe,
        description:
          "The indexed vocabulary and how many spliceable takes exist of each — the question that decides whether a sentence is buildable. Pass word to ask about one word or phrase instead of listing all of them. Narrow with source and min_confidence. Counts only what is indexed, never what was said.",
        args: %{
          "word" => %{type: :string, required: false},
          "source" => %{type: :string, required: false},
          "min_confidence" => %{type: :number, required: false},
          "limit" => %{type: :integer, required: false, default: 50}
        }
      },
      %{
        name: "sound_index_search",
        type: :read,
        tier: :safe,
        description:
          "Find a word or phrase in the word indexes, best take (highest confidence) first. Each hit carries source, start_ms and end_ms — that IS a cut, so hits can be handed straight to sound_assemble in the order you want them spoken. Confidence ranks candidates; it is not a probability.",
        args: %{
          "query" => %{type: :string, required: true},
          "source" => %{type: :string, required: false},
          "min_confidence" => %{type: :number, required: false},
          "limit" => %{type: :integer, required: false}
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
        name: "sound_align",
        type: :mutate,
        tier: :restricted,
        description:
          "Give one already-imported studio source a word index by fitting its transcript onto the speech its audio actually contains — the bootstrap that makes sound_index_search and sound_assemble usable at all, since a source with no index cannot be cut from however good its transcript is. There is NO recognizer: voice-activity detection finds where sound happens, and the transcript's words are shared out across those spans by syllable count. The timings are therefore APPROXIMATE, and they are expected to be improved later, word by word. Name the work with event_id (the transcript comes from the phone event; pass transcript too to correct what the transcriber mangled) or with source plus an explicit transcript. The audio must already be in sounds/studio/: this verb never imports, and a source that is not there is refused as not_imported, naming the basename to run sound_import for. Refuses an existing index unless overwrite is true. Reports words, spans, and two quality figures that need no listening: the confidence spread (min/median/max), which is a plausibility check on the RECORDING as a whole rather than a per-word verdict — every word is scored against the same ~200 ms per syllable, so a flat spread is normal and means nothing, while a LOW value means the transcript does not fit the audio at any rate people speak at; and unplaced_ms, the detected speech no word covers, which is exactly the audio trimmed off words that straddled a span boundary. Confidence tops out at 0.9 because 1.0 means hand-marked, so min_confidence 0.95 asks for measured timings alone. Detector tuning: min_span_ms (default 60) rejects shorter activity, min_silence_ms (default 120) is the smallest gap that counts as a gap. Fit tuning: weight syllables (default) or characters, and syllable_ms (default 200), which only scores confidence and never moves a word. Two corrections are ON by default and are what took the first real assembled paragraph from garbled to audibly better: snap_to_energy pulls each word boundary to the nearest strictly quieter frame within snap_window_ms (default 40), so a cut lands at a closure instead of mid-vowel, and reduce_function_words scales unstressed function words (to, the, of) by function_word_scale (default 0.55), because they run far shorter in real speech than a syllable count suggests and otherwise eat their neighbours' onsets. Both exist to be turned OFF: a change to how something SOUNDS can only be judged by listening to the pair, so align the same source twice and compare by ear rather than trusting the numbers.",
        args: %{
          "event_id" => %{type: :integer, required: false},
          "source" => %{type: :string, required: false},
          "transcript" => %{type: :string, required: false},
          "min_span_ms" => %{type: :number, required: false, default: 60},
          "min_silence_ms" => %{type: :number, required: false, default: 120},
          "weight" => %{
            type: :string,
            required: false,
            enum: ["syllables", "characters"],
            default: "syllables"
          },
          "syllable_ms" => %{type: :number, required: false, default: 200},
          "snap_to_energy" => %{type: :boolean, required: false, default: true},
          "snap_window_ms" => %{type: :number, required: false, default: 40.0},
          "reduce_function_words" => %{type: :boolean, required: false, default: true},
          "function_word_scale" => %{type: :number, required: false, default: 0.55},
          "language" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_index_import",
        type: :mutate,
        tier: :restricted,
        description:
          "Store a word index for one studio source from a supplied word list (each entry: text and/or word, start_ms, end_ms, optional confidence). This is how timings enter the system — there is no recognizer here. Unusable entries are dropped and reported as dropped, not fatal. Refuses an existing index unless overwrite is true, because a hand-corrected index is real work.",
        args: %{
          "source" => %{type: :string, required: true},
          "words" => %{type: :list, required: true},
          "origin" => %{
            type: :string,
            required: false,
            enum: ["manual", "recognizer", "imported"],
            default: "imported"
          },
          "language" => %{type: :string, required: false},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_index_delete",
        type: :mutate,
        tier: :restricted,
        description:
          "Delete one source's word index. The audio itself is untouched — only the timings are lost, and re-creating them means re-importing a word list.",
        args: %{"source" => %{type: :string, required: true}}
      },
      %{
        name: "sound_find",
        type: :mutate,
        tier: :restricted,
        description:
          "Find every other occurrence of a word across the corpus from ONE known instance of it, by acoustic similarity, and add what it finds to the word indexes as origin recognizer. This is the only verb whose timings come from a matcher rather than a guess: sound_align shares a transcript out proportionally, this one compares MFCC features with dynamic time warping. It does NOT transcribe and it cannot find a word you have no example of — the workflow is sound_transcript_search or sound_index_search to locate one take, confirm it by ear, then run this to find the rest. Give it source plus start_ms and end_ms (a confirmed span, e.g. a hit from sound_index_search) and the word that span is an instance of. targets defaults to every indexed source; naming a source that has no index creates one from these matches alone. THRESHOLD: distances have no natural scale and must be measured, not assumed. Against 990 labelled pairs of real 8 kHz speech the same-speaker operating point is about 6.0 — precision 0.88, recall 0.93 — with same-word distances running 3 to 9 and different-word ones 5 to 13. The 0.2 to 0.9 band from the synthetic tests does NOT transfer to real speech and a threshold in it matches nothing. Treat 6.0 as a starting point to re-measure against this corpus. The distributions overlap, so this is a SHORTLIST GENERATOR, not an oracle: roughly one returned span in eight is wrong, and matching is speaker- and channel-dependent by design, so the same word from another caller usually will not match. COST: a source whose features are not cached takes about 109 seconds to analyse and about 155 milliseconds once warm. Cold sources are named in cold_sources and are warmed one process each; warm_only true searches only already-cached sources and reports the rest in skipped_sources rather than blocking for minutes, and refuses outright if the TEMPLATE source is itself uncached. write false searches and reports without touching any index. A match overlapping a word the index already has is skipped unless overwrite is true, because a hand-corrected timing is real work. Reports per source: matches with distances, what was added, and the index's previous origin — origin belongs to the whole index file and has no mixed value, so a merged index reads recognizer while its older aligned words are unchanged and still approximate.",
        args: %{
          "word" => %{type: :string, required: true},
          "source" => %{type: :string, required: true},
          "start_ms" => %{type: :number, required: true},
          "end_ms" => %{type: :number, required: true},
          "targets" => %{type: :list, required: false},
          "threshold" => %{type: :number, required: false, default: 6.0},
          "limit" => %{type: :integer, required: false, default: 10},
          "warm_only" => %{type: :boolean, required: false, default: false},
          "write" => %{type: :boolean, required: false, default: true},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_sentence",
        type: :mutate,
        tier: :restricted,
        description:
          "Build a whole ramshackle sentence from a phrase in one call: each word is looked up in the word indexes, the takes of it become candidates, a unit-selection lattice picks the cheapest path through them, and the chosen spans are spliced into a new source in sounds/studio/. This is sound_index_search plus sound_assemble with the part nobody was doing in between — CHOOSING which take of each word to use, which is most of the quality. Read the missing field FIRST: any word with no take in the index is refused outright, naming the words, unless allow_missing is true, because a sentence quietly missing three words is the worst failure this feature has. Read selection second: candidates equal to slots means every word had exactly one take and the search decided nothing, so its cost of 0.0 means best-of-one rather than good — the fix for that is more recordings, not different weights. Costs are min-max normalised inside one lattice, so two sentences' totals cannot be compared. imputed counts cost terms filled from the median because the acoustics were unavailable: feature analysis costs about 109 seconds per uncached source, so by default only sources whose features are already cached inform the choice and the rest are imputed and reported; warm true analyses the missing ones first. Splicing options are sound_assemble's (pad_ms 30, fade_ms 8, gap_ms 60, normalize true). weights overrides the selector's six hand-set terms — confidence, duration, boundary, typicality, spectral, level — which are guesses awaiting an operator's ear, not fitted values. Reports which sources it drew from, the duration and peak, and the take chosen for every word. Writes a new SOURCE only: nothing is installed as a chime and nothing is routed.",
        args: %{
          "phrase" => %{type: :string, required: true},
          "name" => %{type: :string, required: true},
          "allow_missing" => %{type: :boolean, required: false, default: false},
          "warm" => %{type: :boolean, required: false, default: false},
          "source" => %{type: :string, required: false},
          "min_confidence" => %{type: :number, required: false},
          "limit" => %{type: :integer, required: false, default: 20},
          "weights" => %{type: :object, required: false},
          "pad_ms" => %{type: :number, required: false, default: 30},
          "fade_ms" => %{type: :number, required: false, default: 8},
          "gap_ms" => %{type: :number, required: false, default: 60},
          "normalize" => %{type: :boolean, required: false, default: true},
          "overwrite" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "sound_assemble",
        type: :mutate,
        tier: :restricted,
        description:
          "Splice an ordered list of cuts (each: source, start_ms, end_ms) into one new audio file in sounds/studio/ — the ramshackle sentence. Each cut is padded outward, micro-faded so the seam does not click, and levelled; cuts are joined with a gap. Defaults: pad_ms 30, fade_ms 8, gap_ms 60, normalize true. Refuses an existing name unless overwrite is true. Writes a new SOURCE only: nothing is installed as a chime and nothing is routed.",
        args: %{
          "name" => %{type: :string, required: true},
          "cuts" => %{type: :list, required: true},
          "pad_ms" => %{type: :number, required: false, default: 30},
          "fade_ms" => %{type: :number, required: false, default: 8},
          "gap_ms" => %{type: :number, required: false, default: 60},
          "normalize" => %{type: :boolean, required: false, default: true},
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
          "Join whole studio sources end to end, in the order given, as one NEW source. Every source must share a format — joining a 44.1 kHz clip onto a 22.05 kHz one would play the first at half speed, so a mismatch is refused as format_mismatch rather than resampled. Naming the same source twice joins it twice, on purpose. This is a bare join: no padding, no fade, no gap, so every seam is a hard cut. To splice SPANS out of recordings into a sentence, use sound_assemble instead, which pads and micro-fades each piece. An existing name is refused unless overwrite is true.",
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
          "Delete one studio source from sounds/studio/. Only the studio's working material — the sound library and the routing table are untouched, and this cannot remove a chime that is currently playing for something. A source that still has a word index is REFUSED as source_indexed, because deleting the audio would leave a word list whose every hit resolves to nothing; pass delete_index true to remove both, which also destroys any hand-corrected timings. Irreversible: an imported voicemail can be imported again, but an assembled sentence cannot.",
        args: %{
          "name" => %{type: :string, required: true},
          "delete_index" => %{type: :boolean, required: false, default: false}
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
        name: "sound_gaps",
        type: :read,
        tier: :safe,
        description:
          "What the word corpus is MISSING, which is the question sound_index_words cannot answer. Returns distinct_words, total_takes, cuttable (words with 2 or more takes), and single_take — the words with exactly one. That last list is the point: a word with one take is a quotation, not a cut-up, and splicing it produces the same recording every time. Pass target (a list of words, or one string that gets split on whitespace) to also get missing — the target words with NO take at all, which is what makes a sentence impossible before anything is built. by_take_count is sorted most-covered first and limit caps it. origins counts takes by provenance: aligned is a proportional guess capped at 0.9 confidence, recognizer came from sound_find, manual was marked by ear and is the only origin worth 1.0. unreadable_sources counts index files that would not load, so a low indexed_sources says why. An empty corpus reports zeros, not an error.",
        args: %{
          "target" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false}
        }
      },
      %{
        name: "sound_devices",
        type: :read,
        tier: :safe,
        description:
          "Audio input devices that could be recorded from, with name, transport (builtin, usb, bluetooth, virtual, unknown), channels, sample_rate_hz, and which is the system default. Read from system_profiler, not ffmpeg — ffmpeg's device list gives a name and nothing else. TWO CAVEATS THAT MATTER: sample_rate_hz is the device's ADVERTISED capability, not what an open stream will actually run at, so never quote it as the rate of a recording. And a Bluetooth headset opened as an INPUT drops from A2DP to HFP, which is 8 kHz narrowband — near the phone-quality audio the corpus is trying to escape — so a recording made over one is close to worthless for cut-up work. Bluetooth-LE devices may report transport unknown rather than bluetooth, so treat unknown as unproven rather than safe.",
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
          "Record from an input device into sounds/studio/ as a new source — duration-bounded (seconds, up to 300), optional name and device, default input when device is omitted. Gated because it opens the MICROPHONE, and an unattended run acting on content it did not choose must not do that without a person saying yes. READ THIS BEFORE RELYING ON IT: on macOS this path can return perfect digital SILENCE with a zero exit code and nothing on stderr, because microphone consent is granted to the responsible process and the chain here is the BEAM spawning ffmpeg, which carries neither an Info.plist nor an entitlement of its own. Measured 08-09: a real capture produced a valid WAV whose every sample was zero, and no consent prompt ever appeared. So the result is read back and a silent take is REFUSED rather than stored, returning silent_capture with the reason. Reports peak and clipped so a bad take is caught at the door. A name collision de-duplicates rather than overwriting, because the capture already happened and cannot be retaken. This is a convenience for a trusted caller; the operator's recording path is the in-app recorder, which captures inside the signed app where consent can be attributed.",
        args: %{
          "seconds" => %{type: :number, required: true},
          "name" => %{type: :string, required: false},
          "device" => %{type: :string, required: false}
        }
      }
    ]
end
