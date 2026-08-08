defmodule BusterClaw.Commands.Catalog.Sound do
  @moduledoc """
  Catalog entries: the sound library, its routing table, the Sound Studio's
  imported clips, and the cut-up surface — searching recordings for words and
  splicing them into new sources (STUDIO_ROADMAP Part I Phase 0, Part III
  Phases A/B).

  The reads are `:safe`: they open files read-only, touch no setting, and change
  nothing about what the machine plays.

  Three entries write, and all three are `:restricted`. None is `gated`, and the
  line is worth stating: `sound_assemble` writes a **new source** into
  `sounds/studio/`, and `sound_index_*` write text beside it. Nothing here
  installs a chime or routes a key — routing is the only act that changes what
  the machine does when nobody is watching, and it stays a later, gated phase.
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
          "Inspect one sound or studio source by name: sample rate, channels, bits, duration_ms, peak level, and whether it is already in the Studio's internal PCM16 mono 22.05 kHz format. Resolves a workspace library file first, then a bundled default, then a studio source. The only way to learn what a sound actually is without listening to it.",
        args: %{"name" => %{type: :string, required: true}}
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
      }
    ]
end
