defmodule BusterClawWeb.Explained.Vox do
  @moduledoc """
  The Vox2B tutorial — the surface where the app's voice is made.

  Added 09-05, the day the voice became a Home sub-tab of its own. Until then it
  was a Settings page (`/voice` off the Settings rail) and Explained had no entry
  for it, which was defensible while it was a settings screen and stopped being
  so the moment it became one of six things on the home rail.

  ## The two things this page exists to prevent

  **Confusing the two engines.** Four of the five Vox2B tabs drive VoxCPM: a 2B
  model, installed by the operator, minutes per line, output is a file. The fifth
  — Reading aloud — drives `say(1)`, which is instant, on-device and reads chat
  replies live. They are on one surface because they are both "the app talking";
  they are not interchangeable and nothing here should suggest they are.

  **Confusing Vox2B with the Studio's Voice Library.** Voice Library splices
  words the operator has already said out of real recordings and can never say
  anything else. Vox2B synthesizes. Both tutorials now name the other.

  ## What the agent can actually reach

  Four verbs, all about spoken messages. Recording a reference clip, changing the
  engine settings and publishing the phone greeting have no commands at all —
  they are screen acts. This page says so rather than leaving a reader to infer a
  verb that does not exist.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  def vox_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The voice</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Vox2B — the machine talks, and it sounds like you
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          A synthesized chime tells you <span class="italic">that</span>
          something happened. A spoken one tells you <span class="font-semibold text-base-content">what</span>, from the next
          room, without going to look. Vox2B is where those lines are made — and
          the voice they are made in is a ten-second recording of your own.
        </p>
        <p>
          It is a tab on this same home screen, with five panes down its left
          edge: <span class="font-mono text-base-content">Create</span>
          makes audio, <span class="font-mono text-base-content">Files</span>
          holds what was made, <span class="font-mono text-base-content">Alerts</span>
          decides where it is heard, <span class="font-mono text-base-content">Engine</span>
          is the machinery, and <span class="font-mono text-base-content">Reading aloud</span>
          is a different synthesizer entirely.
        </p>
      </div>

      <section class="flex flex-col gap-3" id="explained-vox-engines">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Two engines on one tab, and they are not alike
        </h3>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">VoxCPM</span>
            — a 2B speech model you install yourself. It clones a few seconds of
            your voice and can say anything, and it takes
            <span class="font-semibold text-base-content">minutes per line</span>
            on a laptop. Everything it makes is a file. Create, Files, Alerts and
            Engine all drive this.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">say(1)</span>
            — your Mac's own synthesizer, on the
            <span class="font-mono text-base-content">Reading aloud</span>
            tab. Instant, on-device, and it reads each chat reply as it arrives.
            It makes no files and it is not your voice. Toggle it in the chat
            header; the desktop app only, because the synthesizer belongs to it.
          </li>
        </ul>
        <p class="border-l-2 border-primary pl-3 text-sm leading-relaxed text-base-content/80">
          The short version:
          <span class="font-semibold text-base-content">
            VoxCPM pre-renders; <code>say</code> reads live.
          </span>
          Nothing on this page renders a line at the moment you need to hear it —
          a multi-second model load between a timer firing and a sound is not a
          chime, it is a delayed apology.
        </p>
      </section>

      <section class="flex flex-col gap-3">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          The engine is yours, and the app never pretends otherwise
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          VoxCPM is discovered at runtime the way <code>ffmpeg</code>
          is, never bundled: the weights alone are larger than the whole download.
          The Engine tab looks in your login shell's <code>PATH</code>
          and at one fixed path, <code>~/.buster-claw/voxcpm/bin/voxcpm</code>,
          which is where the install instructions put it.
        </p>
        <p class="text-sm leading-relaxed text-base-content/80">
          <span class="font-semibold text-base-content">There is no "is it working?" button</span>, and its absence is
          deliberate (09-05). The panel reports what is <span class="italic">installed</span>; it does not claim to know whether
          the thing runs. Running VoxCPM at all pays a full model import, so a
          liveness check is expensive and still answers a smaller question than
          typing a line into Create and hearing it back. A broken install reports
          itself in the render note of the first thing you ask for.
        </p>
      </section>

      <section class="flex flex-col gap-3">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          The recording is the training
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          There is no training step. VoxCPM clones zero-shot: hand it a few
          seconds of someone speaking and it speaks as them. So "teach it my
          voice" is not a job that runs — it is a file that saves. The moment a
          take lands, every chime, clip and greeting is rendered in it.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">Under two seconds is refused</span>
            — the engine has heard a syllable, not a voice, and the result is not
            a bad render, it is a stranger's voice with no warning.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">Silence is refused</span>
            — a muted input produces a file of zeros and exit 0, which is worse
            than an error. Ten seconds read at normal speed is comfortable.
          </li>
          <li>
            The microphone is opened by the desktop app, not by the BEAM, because
            entitlements do not cross process boundaries. In a plain browser tab
            the recorder says what stopped it rather than failing quietly.
          </li>
        </ul>
      </section>

      <section class="flex flex-col gap-3">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Everything is rendered once, and the cache is the feature
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          A render is addressed by <span class="font-semibold text-base-content">what was asked for, not by when</span>: the hash of the exact
          command line. Ask for the same sentence in the same voice on the same
          device and you get the file that already exists, instantly, without
          waking the queue. Renders themselves run
          <span class="font-semibold text-base-content">one at a time</span>
          — two of these running together on a laptop do not take half the time
          each, they swap.
        </p>
        <p class="text-sm leading-relaxed text-base-content/80">
          The corollary is the thing to know before you touch the Engine tab: <span class="font-semibold text-base-content">
            changing the voice, the device or a knob makes every line you have
            already made stale
          </span>, because it is a different ask and therefore a different file.
          That is correct — a chime rendered in the old voice <span class="italic">should</span>
          be replaced — and on a slow machine it is an evening. So the panel says
          it in numbers, how many of the sixteen chimes are still made under the
          current settings, rather than letting you find out at the button.
        </p>
      </section>

      <.example
        n={1}
        title="Leave yourself a message in your own voice"
        want="A line you will actually hear, said by you, without recording it every time."
        needs="The speech engine installed. A reference clip too, if you want it in your voice — with none recorded the line still renders, in a voice that is not yours."
        touches="Renders one audio file into the workspace and adds a row to the message manifest. Nothing is fired and nothing plays yet."
        confirm="None. voice_message_create is a restricted, audited mutation and is not gated — it makes a file and stops."
        result="A row on Vox2B → Alerts with ready=false, flipping to ready when the audio lands. Minutes, not seconds. No engine installed and the create says so rather than leaving a row that never becomes audible."
      >
        <.prompt text="Make me a spoken message called stand-up that says: time to get out of the chair. Tell me when the audio is actually ready." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="voice_message_create" />
            takes a name (letters, digits and dashes) and the text to say. It
            <span class="font-semibold text-base-content">returns at once with ready=false</span>
            and leaves the engine working. Nothing waits on a render here — minutes
            is a plausible duration, and a call that long is a crash looking for a
            reason.
          </li>
          <li>
            <.copy_command command="voice_message_list" />
            is how you find out it landed: name, text, whether the audio is ready,
            and whether it has been installed as a library sound. It is a <span class="font-semibold text-base-content">safe-tier read</span>, so
            an agent can poll it without any of this being consequential.
          </li>
          <li>
            Readiness is read off the disk on every listing rather than tracked by
            a process. There is nothing supervising the render, which is also why
            there is nothing that can be left half-done.
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Have it go off at a time"
        want="The room hears your own voice say the thing — now, in forty minutes, or at four tomorrow."
        needs="A message whose audio is ready. One that is still rendering is refused as not_ready rather than fired silently."
        touches="Creates one notification carrying that message's sound. The modal, the snooze and the audit row are the ordinary notification ones."
        confirm="None — restricted and audited, not gated. Deleting one is the same: restricted, and it removes the library sound with it."
        result="A notification that speaks the line and shows the words. It says what it says regardless of which chime the reminder key is routed to."
      >
        <.prompt text="Fire my stand-up message in 40 minutes, and again at 4pm tomorrow." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="voice_message_fire" /> takes the name, and optionally
            <code>in_seconds</code>
            (a timer) or <code>at</code>
            (an ISO-8601 alarm) — the same two shapes <code>notify_create</code>
            already accepts. With neither, it fires now.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              A spoken message is a notification whose sound is a rendered line.
            </span>
            That is the whole design: a ready message is installed into the sound
            library as <code>message-&lt;name&gt;.wav</code>, and the notification
            names that file directly. No new playback path, no new scheduler.
          </li>
          <li>
            <.copy_command command="voice_message_delete" />
            removes the message and its library sound. It is restricted like the
            other two and it is <span class="font-semibold text-base-content">not gated</span>
            — worth knowing, because most delete verbs in this app are.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-vox-verbs">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Where a made line can end up — and what has no verb at all
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          The Alerts tab is three destinations, not one:
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">Spoken chimes</span>
            — one short line per routing key, sixteen of them, seeded and every
            one editable. This is the machine talking to the person who owns it; a
            sentence you cannot change is a sentence you will stop hearing. Making
            the whole set is one model load and tens of minutes, and you can leave
            the tab while it runs.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">Spoken messages</span>
            — the two cycles above. They lived in Settings → Notify until 09-05
            and moved here, where the voice that makes them is.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">The phone greeting</span>
            — what a stranger hears when they dial your number. It is <span class="font-semibold text-base-content">
              the only thing in this app that changes what other people
              experience
            </span>, so publishing is a deliberate act with a confirmation in
            front of it, never a side effect of editing the text. Editing the line
            changes nothing until you publish, and the panel tells you when the
            two have drifted apart.
          </li>
        </ul>
        <p class="text-sm leading-relaxed text-base-content/80">
          There is a fourth door on Files:
          <span class="font-semibold text-base-content">Use as a sound</span>
          copies a clip up into the sound library, after which Settings → Notify
          can route it at any alert. Notify needed no change to start offering
          them — the clips were already in a subdirectory of the folder its menu
          reads. It does not route the clip anywhere; <span class="italic">where</span>
          a sound plays stays one decision made in one place. One caveat worth
          carrying: a routing key with nothing assigned resolves to the first file
          alphabetically, so adding files can change what an unrouted alert plays.
        </p>
        <p class="rounded-sm border-l-2 border-warning pl-3 text-sm leading-relaxed text-base-content/70">
          <span class="font-semibold text-base-content">
            Four verbs reach this whole surface, and all four are about messages.
          </span>
          Recording your voice, changing the engine settings and publishing the
          greeting have no commands — an agent cannot do them, and asking it to
          will get you a refusal rather than a near-miss. Those are things you do
          on the screen.
        </p>
      </section>

      <button
        type="button"
        phx-click="select_home_tab"
        phx-value-tab="vox"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open Vox2B
      </button>
    </div>
    """
  end
end
