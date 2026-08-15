defmodule BusterClawWeb.Explained.Ramshackle do
  @moduledoc """
  The Ramshackle Voice tutorial — the cut-up engine, explained from the code
  rather than from the roadmap that planned it.

  ## Why this tab exists at all

  Every other tutorial in this rail describes a surface you can point at. This
  one describes a feature that is **mostly** still command-only, and the split
  moved on 08-14: Studio → Voice used to be a placeholder and now shows the
  corpus — the vocabulary and the sentence check (`STUDIO_ROADMAP` VI.1) — while
  recording, aligning, matching and splicing remain verbs.

  So the page's opening claim changed from *"there is no screen for this yet"* to
  which half has one. That is not cosmetic: a tutorial that implies a screen
  exists sends the reader looking for it, and one that denies a screen that now
  exists sends them to the command line for something they could have clicked.
  A lockstep test in `status_live_test.exs` fails if `Voice` returns to being a
  placeholder, which is the same guard that caught this copy the day the tab was
  built.

  ## The facts here are taken from the implementation

  Every number on this page is quoted from the module that owns it, not from
  prose about it. Where they came from, so a later reader can re-check rather
  than re-derive:

  | Claim | Source |
  |---|---|
  | `pad_ms` 30 / `fade_ms` 8 / `gap_ms` 60 and why | `Cutup.Assemble` moduledoc |
  | The six selector weights, `spectral` at 2.0 | `Cutup.Select`'s `@default_weights` |
  | 6.0 threshold, 0.88 precision / 0.93 recall over 990 pairs | `sound_find`'s catalog entry |
  | ~109 s cold, ~155 ms warm feature analysis | `Cutup.Features` moduledoc's measured table |
  | Alignment confidence caps at 0.9 | `sound_align`'s catalog entry |
  | 13 MFCCs per 25 ms frame, cepstral mean normalisation | `Cutup.Mfcc` moduledoc |

  **The one that dates fastest is the threshold.** `sound_find`'s own
  description calls 6.0 "a starting point to re-measure against this corpus" —
  if that operating point is ever re-measured, this page is one of the places
  that has to change with it.

  ## The honesty rules this page follows

  `Cutup.Transcripts` warns that absence of a transcript hit is weak evidence,
  and `Cutup.Gaps` warns that a word with one take is a quotation rather than a
  cut-up. Both are failure modes a reader hits on day one and misreads as the
  feature being broken, so both are stated on the page instead of being left in
  a moduledoc nobody opens.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  def ramshackle_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The cut-up</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Ramshackle Voice — sentences cut out of recordings you already have
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          This is not text-to-speech and it is not a voice clone. There is no model,
          no training, no download and no network. Buster Claw takes audio you
          already have — voicemails, imported files — works out
          <span class="font-semibold text-base-content">
            which recording says which word, and exactly when
          </span>
          — then cuts those words out and splices them into a new sentence nobody
          ever said.
        </p>
        <p>
          The name is the art-historical one. A cut-up is text or tape sliced apart
          and reassembled out of order, and that is literally the mechanism. The
          seams are meant to show. The seams are not meant to <span class="italic">click</span>
          — that part is engineering, and most of this page is about it.
        </p>
        <p class="border-l-2 border-primary pl-3">
          <span class="font-semibold text-base-content">Half of this has a screen now.</span>
          Studio → Voice shows your library of words — every one the corpus holds,
          how many takes of it exist, and whether a phrase you type can be cut
          from them. What it cannot do yet is <span class="italic">record</span>,
          and it says so on its face. Everything below — the aligning, the
          matching, the splicing — is still reachable <span class="italic">only</span>
          through commands, which means through your agent or through <code>./buster-claw</code>. That is the honest division today: the Voice
          tab is where you look at the corpus, and this page is how the engine
          that fills it works.
        </p>
      </div>

      <section class="flex flex-col gap-3" id="explained-ramshackle-pipeline">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          The pipeline, and the one thing in the middle of it
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          Assembling audio was never the hard part — splice, fade, normalize and
          concat all existed and were tested long before this feature. The cut-up is
          an <span class="font-semibold text-base-content">indexing</span>
          problem wearing an audio problem's clothes.
        </p>
        <ol class="ic-unfold">
          <li>
            <span class="font-semibold text-base-content">Get the audio in.</span>
            A voicemail or a file becomes a source in the Studio's folder, converted
            to the internal format (mono PCM16, 22.05 kHz).
          </li>
          <li>
            <span class="font-semibold text-base-content">Give it a word index.</span>
            Per source, a list of words with start and end times. This is the whole
            contract, and everything else is either producing one or consuming one.
          </li>
          <li>
            <span class="font-semibold text-base-content">Search it.</span>
            "Which sources say <em>harbor</em>, and when?" Every hit is already a cut.
          </li>
          <li>
            <span class="font-semibold text-base-content">Choose between takes.</span>
            With nine takes of <em>morning</em>
            and thirty-five of <em>to</em>, which
            one goes in slot 4 is <span class="italic">most of the quality</span>. A
            lattice decides it.
          </li>
          <li>
            <span class="font-semibold text-base-content">Splice.</span>
            Pad each cut outward, micro-fade the edges, level it, join with a gap.
            Out comes a new source file.
          </li>
        </ol>
        <p class="text-sm leading-relaxed text-base-content/80">
          One entry per word, per source, is the entire data structure:
        </p>
        <pre
          phx-no-curly-interpolation
          class="overflow-x-auto rounded border border-base-content/20 bg-base-200 p-3 font-mono text-xs leading-relaxed"
        ><code>%{word: "harbor", start_ms: 1240, end_ms: 1480,
    confidence: 0.82, source: "voicemail-03.wav"}</code></pre>
        <p class="text-sm leading-relaxed text-base-content/70">
          Indexes live beside the audio as plain JSON, one file per source, on
          purpose: <span class="font-semibold text-base-content">correcting a bad timing is a text edit</span>. And because the index
          does not care where it came from, a hand-written one, an imported one and a
          matcher's one are all equally valid input.
        </p>
      </section>

      <section class="flex flex-col gap-3" id="explained-ramshackle-origins">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Where timings come from — read this as a confidence ceiling
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          An index records its <code>origin</code>, and origin is a property of the
          whole file rather than of a word. It tells you how much to trust every
          timing in it:
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">aligned</span>
            — a transcript shared out across the speech proportionally, by syllable
            count. <span class="font-semibold text-base-content">Deliberately crude</span>, and confidence
            <span class="font-semibold text-base-content">caps at 0.9</span>
            so it can never impersonate a measurement. This is the bootstrap: the
            matcher needs one example of a word before it can find the rest, and
            somebody has to produce the first one.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">recognizer</span>
            — measured by comparing sound to sound (MFCC features, dynamic time
            warping). The only origin where a machine actually listened.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">manual</span>
            — hand-marked.
            <span class="font-semibold text-base-content">The only origin that earns 1.0.</span>
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">imported</span>
            — a word list supplied from outside, trusted as given.
          </li>
        </ul>
        <p class="text-sm leading-relaxed text-base-content/70">
          So an index that is entirely <code>aligned</code>
          is a vocabulary of estimates, and it will sound like one. That is not a bug
          report; it is the reason the next two cycles exist.
        </p>
      </section>

      <.example
        n={1}
        title="Is this even possible with what I have?"
        want="Before importing anything, find out whether there is enough material to cut up at all."
        needs="Nothing. These are reads over recordings and transcripts already on disk."
        touches="Nothing — no file is written, no index is created, no audio is decoded."
        confirm="None. Every verb in this cycle is a safe-tier read."
        result="Counts and a word list. If recordings_on_disk is 0, the audio lives in another workspace — the search is not broken, the corpus is elsewhere."
      >
        <.prompt text="How much recorded audio do I actually have? Run sound_corpus, then show me the most common words across my transcripts." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_corpus" />
            reports events, how many carry a transcript, how many name a recording,
            and <span class="font-semibold text-base-content">how many of those files are really on disk</span>. That last
            gap is the one that wastes an afternoon if you skip it.
          </li>
          <li>
            <.copy_command command="sound_transcript_words" />
            counts the vocabulary. The question it answers is brutal and worth asking
            early: <span class="italic">how many takes of a given word do I have?</span>
            A word you have once is a word you cannot really use.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              Read the counts as a floor, never a census.
            </span>
            Voicemail transcripts are 8 kHz telephony audio over a stranger's handset,
            and the transcriber mangles it — callers say "Buster Claw" and it writes
            "busted class", "buster clark", "bus o'clock". Real takes hide under
            misrecognitions.
          </li>
          <li>
            Which is also why
            <span class="font-semibold text-base-content">
              an empty search result is weak evidence.
            </span>
            The word may well be in the audio and simply not in the text. Nothing here
            will ever tell you "you have no takes of X" — only "no transcript contains X".
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Turn a recording into something cuttable"
        want="A source with a word index — because a source without one cannot be cut from, however good its transcript is."
        needs="An audio file or a phone event with a recording. Non-WAV audio needs the system decoder (/usr/bin/afconvert), or the import is refused up front as no_decoder rather than failing later."
        touches="Writes one WAV into the Studio's sources folder, then one JSON index beside it. Existing files are refused unless you pass overwrite."
        confirm="Both verbs are restricted-tier mutations and produce an audit receipt. Neither installs a chime and neither routes anything to an event."
        result="An index with a confidence spread and an unplaced_ms figure. A source that was never imported is refused as not_imported, naming the basename to import first."
      >
        <.prompt text="Import the recording from phone event 41 into the Studio, then align it so I can cut words out of it." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_import" />
            brings the audio in and converts it. It reports duration, peak, format, and
            whether the decoder had to run.
          </li>
          <li>
            <.copy_command command="sound_align" /> gives it the index. Understand what it is doing:
            <span class="font-semibold text-base-content">there is no recognizer here.</span>
            Voice-activity detection finds where sound happens; the transcript's words
            are then shared out across those spans by syllable count. It is forced
            alignment for the poor, and the bar it clears is "closer than nothing, and
            honest about it".
          </li>
          <li>
            <span class="font-semibold text-base-content">Two corrections are on by
              default</span>, and they are what took the first real assembled paragraph
            from garbled to audibly better. <code>snap_to_energy</code>
            pulls each boundary to the nearest quieter frame within 40 ms, so a cut
            lands at a closure instead of mid-vowel. <code>reduce_function_words</code>
            scales unstressed words (<em>to</em>, <em>the</em>, <em>of</em>) to 0.55,
            because they run far shorter in real speech than syllables suggest and
            otherwise eat their neighbours' onsets.
          </li>
          <li>
            <span class="font-semibold text-base-content">Both exist to be turned off.</span>
            A change to how something <em>sounds</em>
            can only be judged by listening. Align the same source twice and compare by
            ear — do not trust the numbers over your own hearing.
          </li>
          <li>
            <span class="font-semibold text-base-content">How to read the two quality figures.</span>
            The confidence spread is a check on the <span class="italic">recording as a whole</span>, not a per-word verdict —
            every word is scored against the same ~200 ms per syllable, so a flat
            spread is normal and means nothing, while a low value means the transcript
            does not fit the audio at any rate people speak at. <code>unplaced_ms</code>
            is detected speech no word covers: audio trimmed off words that straddled
            a span boundary.
          </li>
          <li>
            If the transcriber mangled the words, pass the corrected <code>transcript</code>
            yourself. The alignment is only ever as good as the text it is fitting.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="Find every other take of a word, by ear rather than by text"
        want="One confirmed instance of a word, turned into every other instance of it across the whole corpus."
        needs="One confirmed span — a source plus start_ms and end_ms you have actually listened to. Sources whose features are not cached cost about 109 seconds each to analyse."
        touches="Adds matches to the word indexes as origin recognizer, and writes a feature cache per analysed source. write false searches and reports without touching any index."
        confirm="A match that overlaps a word the index already has is skipped unless overwrite is true — a hand-corrected timing is real work and is never clobbered silently."
        result="Per-source matches with distances, what was added, and each index's previous origin. Cold sources are named in cold_sources; warm_only true skips them instead of blocking for minutes."
      >
        <.prompt text="I confirmed that voicemail-03 says 'harbor' from 1240ms to 1480ms. Find every other take of that word across my corpus, but don't write anything yet — show me the distances first." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_find" /> is
            <span class="font-semibold text-base-content">
              the only verb whose timings come from a matcher.
            </span>
            It compares MFCC features with dynamic time warping — arithmetic over
            13 numbers per 25 ms frame, no model, no training data, no network.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              It cannot find a word you have no example of.
            </span>
            It does not transcribe. The workflow is always: locate one take by
            transcript or index search, <em>confirm it by ear</em>, then run this to
            find the rest.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              The threshold is measured, not assumed.
            </span>
            Against 990 labelled pairs of real 8 kHz speech, the same-speaker operating
            point is about <code>6.0</code>
            — precision 0.88, recall 0.93 — with same-word distances running 3 to 9 and
            different-word distances 5 to 13. Treat 6.0 as a starting point to
            re-measure against your corpus, not a constant.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              The distributions overlap, so this is a shortlist generator and not an oracle.
            </span>
            Roughly one returned span in eight is wrong. Matching is speaker- and
            channel-dependent <em>by design</em>
            — the same word from another caller usually will not match, and that is the
            mechanism working, not failing.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              Analysis is expensive once and free afterwards.
            </span>
            About 109 seconds for an uncached source, about 155 milliseconds once
            cached — a 700× difference, and the reason a cache exists at all rather
            than as an optimisation.
          </li>
        </ol>
      </.example>

      <.example
        n={4}
        title="Build the sentence"
        want="A phrase in, an assembled audio file out, with the choice of take made for you."
        needs="Word indexes that between them contain every word in the phrase. Nothing else."
        touches="Writes ONE new source file into the Studio's sources folder. Nothing is installed as a chime and nothing is routed to any event."
        confirm="Restricted-tier mutation with an audit receipt. An existing name is refused unless overwrite is true."
        result="The new source, the sources it drew from, duration and peak, and the take chosen for every word. Any word with no take is refused outright, naming the words, unless allow_missing is true."
      >
        <.prompt text="Build me a ramshackle sentence saying 'the harbor is closed until morning' and call it harbor-warning." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_sentence" />
            is the whole cut-up in one call: look up each word, turn its takes into
            candidates, run a lattice, splice the winning path.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              Read the <code>missing</code> field first.
            </span>
            A sentence quietly missing three words is the worst failure this feature
            has, which is why a missing word refuses the whole call by default rather
            than producing something shorter than you asked for.
          </li>
          <li>
            <span class="font-semibold text-base-content">Read <code>selection</code> second.</span>
            If candidates equals slots, every word had exactly one take and the search
            decided nothing — a cost of 0.0 means <span class="italic">best-of-one</span>, not <span class="italic">good</span>. The fix
            for that is more recordings, never different weights.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              Costs are normalised inside one lattice, so two sentences' totals cannot be compared.
            </span>
            A 0.3 here and a 0.3 there are not the same number.
          </li>
          <li>
            <code>imputed</code>
            counts cost terms filled in from the median because the acoustics were
            unavailable. By default only already-cached sources inform the choice;
            <code>warm: true</code>
            analyses the rest first, at about 109 seconds each.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-ramshackle-lattice">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          The lattice, and the six numbers behind it
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          A sentence is a lattice: one slot per target word, N candidate takes per
          slot. Every path through it is a possible sentence, and the cheapest path
          wins. Two costs shape it — a
          <span class="font-semibold text-base-content">target cost</span>
          (is this take good for this slot, ignoring its neighbours) and a
          <span class="font-semibold text-base-content">join cost</span>
          (does it splice cleanly onto the next one). This is classical
          concatenative-TTS unit selection; the data was already in its shape before
          anyone noticed.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">confidence</span>
            — how much the index trusts this timing.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">duration</span>
            — is this take about as long as the word should be.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">boundary</span>
            — how quiet the take's edges are, so a cut starts from silence.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">typicality</span>
            — does this take sound like the other takes of the same word, or is it the
            odd one out.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">spectral</span>
            — the join term: how well the seam matches acoustically. <span class="font-semibold text-base-content">Weighted 2.0, twice everything else</span>,
            because a bad seam is what the ear notices first.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">level</span>
            — the other join term: do the two takes sit at the same loudness.
          </li>
        </ul>
        <p class="text-sm leading-relaxed text-base-content/70">
          Every term is min–max normalised to 0–1 before it is weighted. Without
          that, the term with the widest raw spread silently becomes the only term
          that matters and the other weights are decorative — with no error and no
          symptom except choices that are quietly poor.
          <span class="font-semibold text-base-content">
            These six weights are hand-set guesses awaiting an operator's ear, not fitted values.
          </span>
          Override them with <code>weights</code>
          and trust what you hear.
        </p>
      </section>

      <.example
        n={5}
        title="Cut it by hand instead"
        want="Full control of every cut — because sometimes you know which take you want."
        needs="A word index that contains the words. Nothing else."
        touches="Writes one new source file. Same as sound_sentence; the difference is only who chose the cuts."
        confirm="Restricted-tier mutation with a receipt. An existing name is refused unless overwrite is true."
        result="A new source in the Studio's folder. Cuts are spliced in exactly the order you listed them — this verb makes no choices at all."
      >
        <.prompt text="Search my indexes for 'harbor', 'closed' and 'morning', show me the hits with their confidences, and then assemble the three best into one clip called by-hand." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_index_search" />
            returns hits best-take-first, each carrying source, start_ms and end_ms.
            <span class="font-semibold text-base-content">A hit IS a cut</span>
            — it can be handed straight to the assembler in whatever order you want it
            spoken.
          </li>
          <li>
            <.copy_command command="sound_assemble" />
            takes that ordered list and splices it. It chooses nothing; you did the
            choosing.
          </li>
          <li>
            Confidence
            <span class="font-semibold text-base-content">
              ranks candidates; it is not a probability.
            </span>
            A 0.82 does not mean 82% correct — it means "better than the 0.61 below it".
          </li>
          <li>
            <.copy_command command="sound_index_words" />
            first if you want to know what is available before you plan the phrase, and
            <.copy_command command="sound_probe" />
            on the result to check duration and peak without listening.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-ramshackle-numbers">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Three numbers that decide whether it sounds like anything
        </h3>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">pad_ms: 30</span>
            — every cut is padded outward before splicing, and
            <span class="font-semibold text-base-content">
              this is the feature working rather than polish.
            </span>
            Word boundaries are approximate and speech co-articulates: a plosive
            (<code>p</code>, <code>t</code>, <code>k</code>) is a <em>silence</em>
            followed by a burst, so the closure sits before the reported onset and
            cutting at the timestamp arrives at a decapitated word. It is deliberately
            not larger — past roughly 50 ms you reliably drag a neighbour's vowel in
            with every cut, and that is a real cost of the technique, not a bug to fix.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">fade_ms: 8</span>
            — a micro-fade on each edge. A hard start is the loudest click a sound can
            make.
            <span class="font-semibold text-base-content">
              Ramshackle means the seams show, not that the seams click.
            </span>
            Keep it well below <code>pad_ms</code>: the fade is meant to consume
            padding, not word. Set it larger than the padding and the ramp reaches into
            the syllable's onset — exactly the decapitation the padding prevents.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">gap_ms: 60</span>
            — the join between words. Under about 40 ms the words run together and it
            reads as one slurred phrase; at 150 ms and up it reads as someone dictating
            a word list. 60 ms is roughly a stop closure: audible as a seam, legible as
            a sentence.
          </li>
        </ul>
      </section>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/70">
        <p>
          <span class="font-semibold text-base-content">What this will not do.</span>
          It does not transcribe — no verb here turns unknown audio into text.
          It does not classify sounds: "find the door slam" needs a model and is out of
          scope, whatever the vocabulary suggests. It does not work across speakers —
          matching is speaker- and channel-dependent by design, so another caller's
          "harbor" usually will not match yours.
          <span class="font-semibold text-base-content">None of these verbs record</span>
          — every one of them works on audio that already exists, which is precisely
          why this half could be built at all while the microphone path could not.
          Capturing new audio to grow the corpus is a separate capability, being built
          alongside this one; when it lands it feeds the same word indexes, and nothing
          on this page changes. And it never routes anything —
          <span class="font-semibold text-base-content">
            every assembling verb writes a new source and stops.
          </span>
          Nothing becomes a chime and nothing plays on an event unless you install it
          yourself.
        </p>
        <p>
          <span class="font-semibold text-base-content">
            The number that decides whether any of this is worth it.
          </span>
          A word with exactly one take is a quotation, not a cut-up: splicing it
          reproduces the speaker saying it, at the one pitch and pace they happened to
          use, and nothing was assembled because there was no choice to make. Coverage
          is the whole game — and the fix for a thin corpus is always more recordings,
          never more tuning.
        </p>
        <p>
          <span class="font-semibold text-base-content">Why an index is a text file.</span>
          A recogniser mis-hears; an alignment guesses. Both are expected to be wrong
          somewhere, and the design's answer is that correcting them is an ordinary
          edit to an ordinary JSON file sitting next to the audio it describes. An
          operator who can find the file can make the cut-up work.
        </p>
      </div>

      <.link
        navigate="/cmd-list"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> See every sound_ command
      </.link>
    </div>
    """
  end
end
