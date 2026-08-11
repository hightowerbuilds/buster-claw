defmodule BusterClawWeb.Explained.Phone do
  @moduledoc """
  The BusterPhone tutorial — the answering machine and SMS relay.

  The load-bearing concept is the difference between **recording** a message and
  **enqueueing** it as agent work. An answering machine records strangers by
  design; that is what an answering machine is for. Turning a stranger's voice
  into agent work would put untrusted content on the queue, so the trust
  decision is drawn after the archive, never before it, and the two kinds of
  message do not use the same rule:

  - **SMS** needs a trusted number. One factor.
  - **Voicemail** needs a trusted number **and** a PIN-verified call. Two.

  Anything that fails a gate is still recorded and still playable. That
  asymmetry is the tutorial's spine and every claim below is checked against
  `Telephony.Drain`, `Telephony.Pins`, and the telephony catalog by
  `status_live_test.exs`.

  Honest about setup: this surface is the one that needs the operator's own
  Twilio number and Supabase relay today — the number counter on busterclaw.lol
  is planned, not open. The tutorial says so rather than implying a Connect
  button exists.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  def phone_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The phone line</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          BusterPhone — an answering machine that can act
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          Your agent gets a phone number. People call it and leave messages; people
          text it. Everything that arrives is transcribed and archived on this
          machine, in the
          <.link navigate="/phone" class="font-semibold text-primary hover:opacity-80">
            Phone tab
          </.link>
          — a real answering machine, with a blinking light.
        </p>
        <p>
          The one idea worth learning before anything else: <span class="font-semibold text-base-content">recording a message and
            handing it to an agent are two different events</span>, and only the
          first one happens automatically. An answering machine takes strangers'
          messages — that is its job. Agent work is a much shorter list.
        </p>
        <p class="border-l-2 border-primary pl-3">
          <span class="font-semibold text-base-content">Setup, honestly.</span>
          The inbound path is built and shipped, but it runs on
          <span class="font-semibold text-base-content">your</span>
          Twilio number and <span class="font-semibold text-base-content">your</span>
          Supabase relay. Put both in
          <.link navigate={~p"/settings"} class="underline hover:text-base-content">
            Settings → Configuration → Service credentials
          </.link>
          — they take effect immediately, with no restart, and can be cleared
          again from the same place. Setting them as environment variables still
          works for development, but a double-clicked app cannot see variables
          exported in your shell, so the settings screen is the path that works
          in a real install. There is no one-click
          number yet — buying one from
          <span class="font-semibold text-base-content">busterclaw.lol</span>
          is planned work, not a store you can visit. Until then this tab is the
          map, and the Phone tab shows an empty machine.
        </p>
      </div>

      <figure class="flex flex-col gap-2">
        <svg
          viewBox="0 0 560 268"
          role="img"
          aria-label="An inbound call or text goes to Twilio, then a signed edge function, which asks voice callers for an access code. Both land on the Supabase relay queue, which the Mac-side drain pulls into the local SQLite archive — persist first, acknowledge second. Every inbound message is archived and playable. Only then is the trust decision made: a trusted number's text becomes a Dispatch item, a trusted number's PIN-verified voicemail becomes a Dispatch item, and everything else stays archived only."
          class="w-full text-base-content/70"
        >
          <defs>
            <marker
              id="ph-arrow"
              viewBox="0 0 8 8"
              refX="7"
              refY="4"
              markerWidth="6"
              markerHeight="6"
              orient="auto-start-reverse"
            >
              <path d="M0,0 L8,4 L0,8 z" fill="currentColor" />
            </marker>
          </defs>

          <g fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="10" y="18" width="92" height="40" />
            <rect x="10" y="74" width="92" height="40" />
            <rect x="132" y="46" width="104" height="40" />
            <rect x="266" y="46" width="104" height="40" />
          </g>
          <g class="font-mono" fill="currentColor" font-size="9" text-anchor="middle">
            <text x="56" y="36" font-weight="bold">CALL</text>
            <text x="56" y="49" font-size="7.5">A STRANGER, MAYBE</text>
            <text x="56" y="92" font-weight="bold">TEXT</text>
            <text x="56" y="105" font-size="7.5">A STRANGER, MAYBE</text>
            <text x="184" y="63" font-weight="bold">EDGE FUNCTION</text>
            <text x="184" y="76" font-size="7.5">ASKS FOR THE CODE</text>
            <text x="318" y="63" font-weight="bold">RELAY QUEUE</text>
            <text x="318" y="76" font-size="7.5">DURABLE, UNSYNCED</text>
          </g>

          <g stroke="currentColor" stroke-width="1.5" marker-end="url(#ph-arrow)">
            <line x1="102" y1="38" x2="128" y2="58" />
            <line x1="102" y1="94" x2="128" y2="76" />
            <line x1="236" y1="66" x2="262" y2="66" />
            <line x1="370" y1="66" x2="424" y2="66" />
            <line x1="470" y1="98" x2="470" y2="130" />
            <line x1="470" y1="176" x2="470" y2="200" />
          </g>

          <rect
            x="424"
            y="46"
            width="112"
            height="52"
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
          />
          <g class="font-mono" fill="currentColor" font-size="9" text-anchor="middle">
            <text x="480" y="66" font-weight="bold">THE DRAIN</text>
            <text x="480" y="78" font-size="7.5">PERSIST, THEN ACK</text>
            <text x="480" y="89" font-size="7.5">TRANSCRIPT GRACE</text>
          </g>

          <rect
            x="352"
            y="130"
            width="184"
            height="46"
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
          />
          <g class="font-mono" fill="currentColor" font-size="9" text-anchor="middle">
            <text x="444" y="149" font-weight="bold">ARCHIVED + PLAYABLE</text>
            <text x="444" y="162" font-size="7.5">EVERY MESSAGE, NO EXCEPTIONS</text>
          </g>

          <g class="font-mono" fill="currentColor" font-size="7.5" text-anchor="end">
            <text x="344" y="152">the machine records</text>
            <text x="344" y="163">strangers by design</text>
          </g>

          <g fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="352" y="200" width="184" height="52" />
          </g>
          <g class="font-mono" font-size="9" text-anchor="middle">
            <text x="444" y="218" fill="var(--color-primary)" font-weight="bold">
              THEN THE TRUST DECISION
            </text>
          </g>
          <g class="font-mono" fill="currentColor" font-size="7.5" text-anchor="middle">
            <text x="444" y="231">TEXT: TRUSTED NUMBER → DISPATCH</text>
            <text x="444" y="243">VOICEMAIL: TRUSTED + PIN → DISPATCH</text>
          </g>

          <g class="font-mono" fill="currentColor" font-size="7.5">
            <text x="14" y="212" font-weight="bold">EVERYTHING ELSE</text>
            <text x="14" y="224">stays archived only —</text>
            <text x="14" y="236">recorded, playable,</text>
            <text x="14" y="248">never agent work</text>
          </g>
        </svg>
        <figcaption class="text-xs leading-relaxed text-base-content/60">
          The drain marks a relay row synced only after the local insert succeeds, so
          a crash mid-flight re-drains the row rather than losing the voicemail.
          Voicemails with no transcript yet are left queued for a grace window —
          Twilio's transcription callback lands after the recording one.
        </figcaption>
      </figure>

      <section class="flex flex-col gap-3">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Recorded, or actually work?
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          Two rules, deliberately different, because the two channels prove
          different things. Caller ID is trivially spoofable — a number is a claim,
          not a caller. A PIN is knowledge, but knowledge of a code is not proof
          that this is a number you chose to trust. Voicemail asks for both.
        </p>
        <div class="overflow-x-auto">
          <table class="w-full border-collapse text-left text-xs">
            <thead>
              <tr class="border-b-2 border-base-content/20">
                <th class="ic-eyebrow py-2 pr-3">Arrives as</th>
                <th class="ic-eyebrow py-2 pr-3">Always</th>
                <th class="ic-eyebrow py-2">Becomes Dispatch work when</th>
              </tr>
            </thead>
            <tbody class="text-base-content/75">
              <tr class="border-b border-base-content/10">
                <td class="py-2 pr-3 font-mono font-bold text-base-content">Text</td>
                <td class="py-2 pr-3">Archived, threaded by number</td>
                <td class="py-2" data-phone-sms-rule>
                  the sender's number is on your trusted list.
                  <span class="font-semibold text-base-content">No PIN involved.</span>
                </td>
              </tr>
              <tr class="border-b border-base-content/10">
                <td class="py-2 pr-3 font-mono font-bold text-base-content">Voicemail</td>
                <td class="py-2 pr-3">Recorded, transcribed, playable</td>
                <td class="py-2" data-phone-voicemail-rule>
                  the caller's number is trusted
                  <span class="font-semibold text-base-content">and</span>
                  the call was PIN-verified. Two factors, both required.
                </td>
              </tr>
              <tr>
                <td class="py-2 pr-3 font-mono font-bold text-base-content">Anything else</td>
                <td class="py-2 pr-3">Archived the same way</td>
                <td class="py-2">never. A stranger is a message, not an instruction.</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-sm leading-relaxed text-base-content/70">
          A trusted number that calls and skips the code is the interesting case: it
          is recorded, it is <span class="italic">not</span>
          enqueued, and the near-miss is logged rather than swallowed — because
          either you forgot to punch your PIN, or somebody is spoofing you, and both
          are worth seeing. Inbound messages are also filed on the
          <.link navigate="/security" class="font-semibold text-primary hover:opacity-80">
            Security feed
          </.link>
          as untrusted ingest, the same posture email bodies get.
        </p>
      </section>

      <.example
        n={1}
        title="Check the machine"
        want="The safest thing in this tutorial: look without touching."
        needs="The Phone tab works with an empty archive; real messages need your Twilio number and relay configured."
        touches="Reads the local phone archive only. Marks nothing heard, sends nothing, changes no policy."
        confirm="None — these are safe-tier reads, the tier an agent triaging a voicemail is allowed."
        result="Counts and a list in chat. With no messages yet you get zeros and an empty list — an empty machine, not an error."
      >
        <.prompt text="What's on the answering machine? Anything I haven't heard yet?" />
        <ol class="ic-unfold">
          <li>
            <code>phone_stats</code> is the blinking light as a number: voicemails,
            unheard, texts, calls, and voicemail spend so far.
          </li>
          <li>
            <code>phone_list</code>
            with <code>unheard_only</code>
            gives you just the
            new ones, newest first (filter by <code>kind</code>
            — <code>voicemail</code>, <code>sms</code>, <code>call</code>).
          </li>
          <li>
            Both are reads. Crucially, neither clears the light: asking what is on
            the machine is not the same as having listened to it.
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Reading is not hearing"
        want="Get the transcript — and decide for yourself when the light goes out."
        needs="At least one voicemail in the archive."
        touches="`phone_get` reads one message with its transcript and recording path. `phone_mark_heard` writes: it clears that message's unheard flag."
        confirm="No gate on either. `phone_mark_heard` is a restricted, audited mutation — the control is that it is a separate, explicit verb the agent has to be asked for."
        result="Transcript in chat; the Phone tab's unheard count drops only after mark-heard runs. On a bad id you get a not-found, not a silent no-op."
      >
        <.prompt text="Read me the voicemail from this morning. Leave it marked unheard — I want to listen to the audio myself later." />
        <ol class="ic-unfold">
          <li>
            <code>phone_get</code> returns the transcript, the body, and the path to
            the recording. <span class="font-semibold text-base-content">It deliberately does not
              mark the message heard.</span>
          </li>
          <li>
            The blinking light is yours. An agent skimming the log must not clear it
            behind your back, so clearing it is its own verb: <code>phone_mark_heard</code>, which you have to ask for.
          </li>
          <li>
            The audio itself plays in the Phone tab's Playback panel, streamed from
            the recording the drain filed in your Library — the transcript is a
            convenience, the recording is the record.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="Decide who can give orders"
        want="Turn a number into a trusted one — and add the second factor."
        needs="A number in E.164 form (+15035551234). A PIN must be 4–10 digits."
        touches="Writes policy: the trusted-number list, and the caller-PIN table. `phone_pin_set` hashes the PIN here and stores hash + salt on the relay — the plaintext never leaves this machine."
        confirm="All four write verbs are policy-gated: an untrusted-provenance run is blocked and files a pending approval instead. Deciding who may drive the queue is as consequential as a send."
        result="The number appears in `phone_trusted_list`; `phone_pin_list` shows it has a PIN, with failed-attempt telemetry and never the hash. With no relay configured these fail closed with a not-configured error rather than half-writing."
      >
        <.prompt text="Trust my mobile, +1 503 555 1234, and set its access code to 4815 so my voicemails can actually become work." />
        <ol class="ic-unfold">
          <li>
            <code>phone_trusted_add</code>
            puts the number on the list — that alone is
            enough for <span class="font-semibold text-base-content">texts</span>
            from it to become Dispatch work.
          </li>
          <li>
            <code>phone_pin_set</code> adds the second factor voicemail requires. On
            the call, the greeting asks for an access code before the beep; punching
            it is what flips the call to verified.
          </li>
          <li>
            Both are gated, and so are their undos — <code>phone_trusted_remove</code>
            and <code>phone_pin_remove</code>. Removing
            trust does not delete history: past messages stay archived, future ones
            simply stop being enqueued.
          </li>
          <li>
            <code>phone_trusted_list</code> and <code>phone_pin_list</code> are reads,
            but restricted ones — the allowlist is exactly the recon a spoofer
            wants, so a voicemail-triage run cannot read it. It does not need to:
            its item is already on the queue.
          </li>
        </ol>
      </.example>

      <.example
        n={4}
        title="The message that answers itself"
        want="You call your own number from the road, and the work is done before you're back."
        needs="Your number trusted, a PIN set, the relay drain running, and an on-duty shift."
        touches="Records and archives the voicemail, then enqueues one Dispatch item. The agent's own run then does whatever the message asked for, under its own gates."
        confirm="Two factors before the item is ever created (trusted number + PIN-verified call), then every command the run makes is subject to its own tier and gates — an unattended run does not get a wider surface."
        result="A `voicemail-triage` item on the queue, worked and marked done, with the run's receipts on the Security feed. No PIN, no item — and a warning logged so the near-miss is visible."
      >
        <.prompt
          label="You say, into the phone"
          text="It's me. Move tomorrow's 9am to Thursday and let the other three know, then leave the details in my notes."
          try_in_chat={false}
        />
        <ol class="ic-unfold">
          <li>
            The edge function asks for your code; you punch it, then leave the
            message. The recording and its transcript drain to this machine.
          </li>
          <li>
            Trusted <span class="font-semibold text-base-content">and</span>
            verified, so the drain enqueues a Dispatch item with the <code>voicemail-triage</code>
            role — durable work, not a chat message
            that scrolls away.
          </li>
          <li>
            An on-duty shift picks it up and works it. What it may actually do is
            the ordinary command surface with the ordinary gates: rescheduling and
            note-writing go through, and anything outbound still meets its own
            confirmation.
          </li>
          <li>
            No code punched? Recorded, playable, and
            <span class="font-semibold text-base-content">not</span>
            enqueued — plus a logged warning, because a trusted number that skipped
            the PIN is either you forgetting or someone pretending.
          </li>
        </ol>
      </.example>

      <.example
        n={5}
        title="Texting back"
        want="The sharpest verb on this tab, and the one most likely to refuse you."
        needs="Twilio credentials, a Messaging Service SID, and the explicit BUSTER_CLAW_SMS_ENABLED switch. Missing any one of them and outbound SMS stays off."
        touches="Sends a real text to a real phone and files the outbound message locally. Irreversible — an SMS cannot be unsent."
        confirm="`sms_send` is policy-gated: an untrusted-provenance run is blocked and files a pending approval. On top of that it is off by default and fails closed."
        result="A receipt with the provider status, and the message in the Phone tab's thread. When it refuses you learn which limit stopped it — disabled, recipient opted out, or the per-recipient daily cap — and nothing half-sends."
      >
        <.prompt text="Text Dana that I'm running fifteen minutes late." />
        <ol class="ic-unfold">
          <li>
            <code>sms_send</code> is deliberately hard to fire by accident. It needs
            outbound texting configured and switched on explicitly; until then the
            command refuses rather than pretending.
          </li>
          <li>
            Three limits sit in front of delivery: a
            <span class="font-semibold text-base-content">per-recipient, per-UTC-day
              cap</span>
            (20 unless you change it), an
            <span class="font-semibold text-base-content">opt-out check</span>
            — anyone who has replied STOP stays un-textable until they say START —
            and a length ceiling. Each refusal is specific, so you know which one
            you hit.
          </li>
          <li>
            Sends land on the Security feed as outbound sends. If the provider
            accepts a message but the local write fails, you are told it went out
            and was not filed, rather than being invited to retry into a duplicate.
          </li>
          <li>
            Those STOP/START/HELP replies are compliance traffic: they are archived,
            and they never become agent work. The agent does not get to answer a
            legal opt-out or reinterpret one as a request.
          </li>
        </ol>
      </.example>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/70">
        <p>
          <span class="font-semibold text-base-content">What it costs, and why the
            number moves.</span>
          Voicemail carries a real per-message cost — recording, transcription, the
          call itself — and the provider prices those components on a lag. So the
          figure in <code>phone_stats</code>
          starts provisional and settles: rows keep getting re-priced until every
          component has a final price, and the Phone tab has a refresh for when you
          would rather not wait. A total that grows slightly after the fact is the
          system working, not double-billing.
        </p>
        <p>
          <span class="font-semibold text-base-content">Your number is learned, not
            configured.</span> Nothing stores "the BusterPhone number" — it is read back from the most
          recent inbound message's destination. Before the first call or text ever
          lands, the app genuinely does not know its own number, and says so.
        </p>
      </div>

      <.link
        navigate="/phone"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open the Phone tab
      </.link>
    </div>
    """
  end
end
