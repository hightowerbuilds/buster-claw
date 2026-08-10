defmodule BusterClawWeb.Explained.Studio do
  @moduledoc """
  The Studio tutorial — working material, the editing verbs, and the one verb
  that crosses from *a file exists* to *the machine behaves differently*.

  ## Why this is a separate tab from Ramshackle

  Both tabs are `sound_*` verbs over the same folders, which is exactly why they
  were one tab first and should not have been. They answer different questions:

  - **Studio** (here) — *what does this machine play, and how do I change it?*
    A library, a routing table, four editing verbs, and `sound_apply`.
  - **Ramshackle** (`Explained.Ramshackle`) — *how do I build a sentence nobody
    said, out of recordings I already have?* Word indexes, alignment, a matcher,
    a unit-selection lattice.

  The seam between them is sharp and worth keeping sharp: **Ramshackle produces
  a source; Studio decides whether a source becomes something the machine
  plays.** A reader who wants a custom chime should never have to read about
  dynamic time warping to get one, and that is what the single tab forced.

  ## The spine of this page

  `Catalog.Sound`'s own moduledoc draws the line this tutorial teaches, so the
  page is built on it rather than on a restatement of it: every write verb here
  produces a **new source** in `sounds/studio/` and stops — except `sound_apply`,
  *"the only one that changes what the machine does when nobody is watching"*,
  which is why it carries the gate. `sound_delete` is the other one worth care,
  because it is the only irreversible verb.

  **Do not restore the superlative.** The first draft of this page called
  `sound_apply` the only gated entry in the whole sound surface, which was true
  of the catalog it was written against and false within the day: the capture
  work gates `sound_record` too, for an unrelated reason — it opens the
  microphone. The claim worth making is about *this page's* verbs, and that is
  what `status_live_test.exs` asserts: `sound_apply` gated, every verb the
  tutorial teaches as write-and-stop **un**gated, and `sound_restore_defaults`
  ungated among them. That last one matters as much as the first — it is the way
  back, and gating an undo only ever strands the person who needs it.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  def studio_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Sound</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Studio — the sounds this machine makes, and how to change them
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          Buster Claw makes noise on purpose. A voicemail arrives, a shift ends, a
          terminal command finishes, an alarm fires — each of those can ring, and
          which chime rings is a table you own. The Studio is where you cut the audio,
          and the sound board is where you decide what it is for.
        </p>
        <p>
          There are three separate things here, and confusing them is the usual way
          people get lost:
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">Sources</span>
            — working material in <code>sounds/studio/</code>. Raw, half-edited, yours.
            <span class="font-semibold text-base-content">Nothing in here plays for anything.</span>
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">The library</span>
            — installed chimes in <code>sounds/</code>, in two layers: the bundled
            defaults that ship with the app, and your workspace files, which shadow
            them by name.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">The routing table</span>
            — which library sound each event key uses. Keys inherit: a source key
            falls back to a kind, then to <code>default</code>, then to the bundled
            chime underneath.
          </li>
        </ul>
        <p class="border-l-2 border-primary pl-3">
          <span class="font-semibold text-base-content">
            Only one verb moves a sound from the first bucket to the other two.
          </span>
          Everything else writes a new file and stops. That is the safety model of
          this whole surface, and the rest of this page is built around it.
        </p>
      </div>

      <.example
        n={1}
        title="Find out what it plays now"
        want="Before changing a chime, know which one is actually sounding and where it comes from."
        needs="Nothing. Both verbs are safe-tier reads over files and settings already on disk."
        touches="Nothing at all — no file, no setting, no sound played."
        confirm="None, and none is needed: reading the routing table cannot change it."
        result="Every routing key with its label, what is explicitly assigned, and what actually plays after inheritance — including keys that are deliberately silent."
      >
        <.prompt text="What sound plays when a voicemail arrives, and where does that file come from?" />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_routes" />
            is the map. It reports the key, the human label, the explicit assignment
            and — the column that matters — <span class="font-semibold text-base-content">what plays after inheritance</span>. A key with
            nothing assigned is not silent; it is inheriting, and those are different.
          </li>
          <li>
            <.copy_command command="sound_list" /> reports the library across
            <span class="font-semibold text-base-content">both layers</span>
            and tells you which one each name resolves from — and which bundled
            defaults a workspace file is currently shadowing. Read it before proposing
            any change, because "replace the chime" means different things depending on
            which layer it lives in.
          </li>
          <li>
            The keys are fixed and named: <code>default</code>, <code>timer</code>, <code>alarm</code>, <code>reminder</code>, <code>chat</code>, <code>terminal</code>, <code>email</code>, <code>voicemail</code>, <code>manual</code>, <code>confirm</code>, <code>shift</code>, <code>blocked</code>, <code>web</code>, <code>order</code>, <code>sms</code>, <code>security</code>, <code>boot</code>.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-studio-surfaces">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Two surfaces, and what each is for
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          Unlike the Ramshackle engine next door, this half has real screens — and
          they split along the same line as the verbs do.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">Home → Studio → Mix</span>
            — the editor. Every piece of working material down the left, the selected
            one open on the right. The facts it shows — duration, peak, format, which
            layer it came from — are <span class="font-semibold text-base-content">read from the file, not guessed from its name</span>, so what the panel
            claims is what an edit would actually operate on.
          </li>
          <li>
            <.link
              navigate="/notify-settings"
              class="font-semibold text-primary hover:opacity-80"
            >
              Settings → Notify
            </.link>
            — the sound board: the library and the routing map, with a preview button
            per file. The <span class="font-semibold text-base-content">Test</span>
            button is the one to know about — it fires a <span class="italic">real</span>
            notification carrying that row's kind and source, so the whole pipeline
            rings exactly as a live event would rather than just playing the file.
          </li>
        </ul>
      </section>

      <.example
        n={2}
        title="Cut a chime out of a longer recording"
        want="A two-second sound from a source that is currently thirty seconds long."
        needs="A source already in sounds/studio/. Use sound_import to put one there; non-WAV audio needs the system decoder."
        touches="Each verb writes a NEW source and leaves the input untouched. Nothing enters the library and nothing is routed."
        confirm="All four are restricted-tier mutations with audit receipts, and none is gated — because none of them changes what the machine plays."
        result="A new file in sounds/studio/ each time, reported with its duration and peak beside the source's own. An existing name is refused unless overwrite is true."
      >
        <.prompt text="Take my recording harbor.wav, cut the bit from 4 to 6 seconds, fade both ends, and level it up — I want it as a chime candidate." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_trim" />
            cuts a span. Values outside the clip clamp; a span ending at or before it
            starts is refused as <code>empty_selection</code>
            rather than written as a zero-length file.
          </li>
          <li>
            <.copy_command command="sound_fade" /> ramps the edges to true zero.
            <span class="font-semibold text-base-content">This is the fix for the click</span>
            a clip cut from the middle of a recording begins with — a step from silence
            to full amplitude is the loudest artefact a short sound can have.
          </li>
          <li>
            <.copy_command command="sound_normalize" />
            scales the peak to about -1 dBFS. It is <span class="font-semibold text-base-content">peak normalisation, not loudness</span>:
            it makes a quiet clip usable and cannot make a clipped one clean. Compare
            <code>peak</code>
            against <code>source_peak</code>
            to see what it actually did.
          </li>
          <li>
            <.copy_command command="sound_concat" />
            joins whole sources end to end. Formats must match — joining 44.1 kHz onto
            22.05 kHz would play the first at half speed, so a mismatch is refused
            rather than silently resampled. It is a bare join: every seam is a hard
            cut, with no padding and no fade.
          </li>
          <li>
            <.copy_command command="sound_probe" />
            answers "what is this, actually" — sample rate, channels, duration, peak —
            which is how you check an edit did what you meant <span class="italic">without listening to it</span>.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="Make it the sound the machine actually plays"
        want="The finished clip installed in the library and wired to an event."
        needs="A finished source in the studio. Nothing else — the library and the routing table are created as needed."
        touches="Copies the source into the sound library AND repoints one routing key at it. This is the only verb on this page that changes behaviour."
        confirm="GATED — the only verb on this page that is. An unknown route is refused BEFORE the file is written, so a typo can never surface later as a chime that never plays."
        result="Reports what the key played before, so the change can be undone. name_taken and shadows_bundled refuse unless overwrite is true."
      >
        <.prompt text="Install harbor-trim.wav as my voicemail chime, and tell me what it was before so I can put it back." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="sound_apply" />
            does both halves at once — install and route. There is no way to do one
            without the other, on purpose:
            <span class="font-semibold text-base-content">
              a library file nothing points at is clutter, and a route pointing at a
              file that is not there is a silent key.
            </span>
          </li>
          <li>
            <span class="font-semibold text-base-content">Read the refusals as features.</span>
            <code>unknown_route</code>
            fires before anything is written. <code>shadows_bundled</code>
            is the sharp one: naming your file after a bundled default would replace
            the built-in chime for <span class="italic">every</span>
            key falling back to it, not just the one you meant.
          </li>
          <li>
            It reports the previous value.
            <span class="font-semibold text-base-content">Write that down before you move on</span>
            — it is the whole undo.
          </li>
          <li>
            This is the verb where an agent should tell you what it is about to do
            before it does it. Everything else on this page is a file appearing in a
            folder; this one is your machine sounding different at 3am.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-studio-safety">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          The way back, and the one thing you cannot undo
        </h3>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">sound_restore_defaults</span>
            — puts the shipped chimes back. It is restricted but <span class="font-semibold text-base-content">deliberately not gated</span>,
            because it is the exit and gating an exit only strands whoever needs it. It
            <span class="italic">never</span>
            overwrites: a name already present is skipped, because that file is your
            edit. Pass <code>routes: true</code>
            to also clear every assignment so each key inherits again.
            <span class="font-semibold text-base-content">Nothing is ever deleted.</span>
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">sound_delete</span>
            — the irreversible one, and the only verb here that destroys anything. It
            removes working material only; the library and the routing table are
            untouched, and it cannot remove a chime something is currently using. A
            source that still has a word index is
            <span class="font-semibold text-base-content">refused</span>
            as <code>source_indexed</code>, because deleting the audio would leave a
            word list whose every hit resolves to nothing. An imported voicemail can be
            imported again; an assembled sentence cannot.
          </li>
        </ul>
        <p class="text-sm leading-relaxed text-base-content/70">
          Worth noticing what the shape of this surface says: sixteen verbs write
          files, one changes behaviour, one is destructive, and one is the undo. The
          gate is on the smallest possible thing rather than on the whole family —
          which is why an agent can do the tedious ninety percent of an edit without
          ever being in a position to change what your machine does.
        </p>
      </section>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/70">
        <p>
          <span class="font-semibold text-base-content">Where the audio can come from.</span>
          <code>sound_import</code>
          is the door, and its reach is deliberately narrow: a phone event whose
          recording the app itself stored, or a path <span class="italic">relative to the Library root</span>. Absolute paths and
          <code>..</code>
          are refused, so the verb can address your recordings and nothing else on the
          disk. Everything is converted to the studio's internal format on the way in
          — mono PCM16 at 22.05 kHz — so later joins do not hit a format mismatch.
        </p>
        <p>
          <span class="font-semibold text-base-content">Want a sentence nobody ever said?</span>
          That is the neighbouring tab. Ramshackle indexes recordings word by word and
          splices new sentences out of them — and what it produces is an ordinary
          studio source, which means it arrives back here, at <code>sound_apply</code>, like anything else.
        </p>
      </div>

      <.link
        navigate="/notify-settings"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open the sound board
      </.link>
    </div>
    """
  end
end
