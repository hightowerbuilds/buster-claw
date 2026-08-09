defmodule BusterClawWeb.Explore.Cmd do
  @moduledoc """
  The Command List tutorial — the atlas of the command surface: anatomy
  (operation type / trust tier / policy flag), the funnel diagram, then worked
  examples per non-GWS family.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explore.Shared

  alias BusterClawWeb.Explore.Registry

  # The Command List tutorial: the atlas of the command surface. Anatomy first
  # (operation type / trust tier / policy flag), then the funnel diagram and examples
  # per non-GWS family — Gmail/Drive belong to the Gmail/GWS tab and deep
  # browser driving to BrowserControl, so this page stays deliberately light on
  # both. Command names checked against the catalog when written (08-02); the
  # test asserts each still exists.
  def cmd_panel(assigns) do
    assigns = assign(assigns, :command_stats, Registry.command_stats())

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The surface</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          One command surface — a guided atlas
        </h2>
      </div>

      <div
        id="explore-command-taxonomy"
        class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80"
      >
        <p>
          Buster Claw's agent-addressable backend operations share one canonical
          set of
          <span id="explore-command-total" class="font-mono font-bold">{@command_stats.total}</span>
          commands. Some UI-only work — parts of Appearance and Studio, say —
          deliberately stays outside that surface. You do not memorize the
          commands: say outcomes in Chat and let the agent select them. The live,
          complete list is on <.link
            navigate="/cmd-list"
            class="font-semibold text-primary hover:opacity-80"
          >
            Cmd List
          </.link>.
        </p>
        <p>Each command carries three independent pieces of metadata:</p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li id="explore-command-operation-types">
            <span class="font-mono font-bold text-base-content">operation type</span>
            — {@command_stats.read} read, {@command_stats.trigger} trigger, and {@command_stats.mutate} mutate. A read does not change app state, but it
            may still contact a service such as Google, a broker, or the public web.
          </li>
          <li id="explore-command-trust-tiers">
            <span class="font-mono font-bold text-base-content">trust tier</span>
            — {@command_stats.safe} safe and {@command_stats.restricted} restricted.
            The tier controls which callers may invoke a command; it does not say
            whether network traffic occurs. Restricted commands require a trusted
            path.
          </li>
          <li id="explore-command-policy-flags">
            <span class="font-mono font-bold text-primary">policy flag</span>
            — {@command_stats.gated} commands are additionally <code>gated</code>.
            An autonomous run working untrusted-origin content cannot execute one;
            the refusal is filed as a pending approval. Gated is a flag, not a third
            operation type, and command-specific confirmations are separate again.
          </li>
        </ul>
      </div>

      <figure class="flex flex-col gap-2">
        <svg
          viewBox="0 0 560 300"
          role="img"
          aria-label="Chat, terminal, and trusted email funnel through one command surface, past operation types, trust tiers, and policy flags, out to agent-addressable app surfaces. Mutations and triggers land on the Sentinel audit feed."
          class="w-full text-base-content/70"
        >
          <defs>
            <marker
              id="cmd-arrow"
              viewBox="0 0 8 8"
              refX="7"
              refY="4"
              markerWidth="6"
              markerHeight="6"
              orient="auto-start-reverse"
            >
              <path d="M0,0 L8,4 L0,8 z" fill="currentColor" />
            </marker>
            <marker
              id="cmd-arrow-hazard"
              viewBox="0 0 8 8"
              refX="7"
              refY="4"
              markerWidth="6"
              markerHeight="6"
              orient="auto-start-reverse"
            >
              <path d="M0,0 L8,4 L0,8 z" fill="var(--color-primary)" />
            </marker>
          </defs>

          <%!-- Callers --%>
          <g fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="10" y="38" width="116" height="32" />
            <rect x="10" y="94" width="116" height="32" />
            <rect x="10" y="150" width="116" height="44" />
          </g>
          <g class="font-mono" fill="currentColor" font-size="9" text-anchor="middle">
            <text x="68" y="57">CHAT</text>
            <text x="68" y="113">TERMINAL / CLI</text>
            <text x="68" y="168">TRUSTED EMAIL</text>
            <text x="68" y="181">(ON-DUTY)</text>
          </g>
          <g stroke="currentColor" stroke-width="1.5" marker-end="url(#cmd-arrow)">
            <line x1="126" y1="54" x2="192" y2="90" />
            <line x1="126" y1="110" x2="192" y2="110" />
            <line x1="126" y1="172" x2="192" y2="132" />
          </g>

          <%!-- The surface + policy strip --%>
          <rect
            x="200"
            y="56"
            width="160"
            height="108"
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
          />
          <g class="font-mono" fill="currentColor" font-size="10" text-anchor="middle">
            <text x="280" y="80" font-weight="bold">ONE COMMAND</text>
            <text x="280" y="93" font-weight="bold">SURFACE</text>
            <text x="280" y="108" font-size="8">{@command_stats.total} COMMANDS</text>
          </g>
          <rect
            x="210"
            y="120"
            width="140"
            height="32"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-dasharray="4 3"
          />
          <g class="font-mono" fill="currentColor" font-size="8" text-anchor="middle">
            <text x="280" y="134">METADATA</text>
            <text x="280" y="145">TYPE · TIER · FLAGS</text>
          </g>

          <%!-- Surfaces --%>
          <g fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="434" y="14" width="116" height="28" />
            <rect x="434" y="62" width="116" height="28" />
            <rect x="434" y="110" width="116" height="28" />
            <rect x="434" y="158" width="116" height="28" />
            <rect x="434" y="206" width="116" height="28" />
          </g>
          <g class="font-mono" fill="currentColor" font-size="9" text-anchor="middle">
            <text x="492" y="32">MAIL · CALENDAR</text>
            <text x="492" y="80">BROWSER</text>
            <text x="492" y="128">PHONE</text>
            <text x="492" y="176">FILES · DRIVE</text>
            <text x="492" y="224">THE QUEUE</text>
          </g>
          <g stroke="currentColor" stroke-width="1.5" marker-end="url(#cmd-arrow)">
            <line x1="360" y1="76" x2="430" y2="30" />
            <line x1="360" y1="92" x2="430" y2="76" />
            <line x1="360" y1="110" x2="430" y2="124" />
            <line x1="360" y1="128" x2="430" y2="172" />
            <line x1="360" y1="146" x2="430" y2="220" />
          </g>

          <%!-- Audit --%>
          <line
            x1="280"
            y1="164"
            x2="280"
            y2="248"
            stroke="var(--color-primary)"
            stroke-width="2"
            marker-end="url(#cmd-arrow-hazard)"
          />
          <text
            x="292"
            y="210"
            class="font-mono"
            fill="var(--color-primary)"
            font-size="8"
          >
            MUTATES + TRIGGERS
          </text>
          <rect
            x="200"
            y="252"
            width="160"
            height="34"
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
          />
          <text
            x="280"
            y="273"
            class="font-mono"
            fill="currentColor"
            font-size="9"
            text-anchor="middle"
            font-weight="bold"
          >
            SENTINEL AUDIT FEED
          </text>
        </svg>
        <figcaption class="text-xs leading-relaxed text-base-content/60">
          Every caller — you in chat, you in the terminal, a trusted sender's email —
          funnels through the same policy point. Mutations and triggers are receipted
          on the <.link
            navigate="/security"
            class="font-semibold text-primary hover:opacity-80"
          >
            feed
          </.link>; ordinary reads are skipped to keep the signal useful.
        </figcaption>
      </figure>

      <.example
        n={1}
        title="Capture the day"
        want="Notes, documents, reminders — the desk-drawer commands."
        needs="Nothing. These are the commands that work on a fresh install with nothing connected."
        touches="Writes three local things: a markdown file in your Library, a line on today's journal, and one pending reminder. Nothing leaves the machine."
        confirm="None of the three is gated. They are restricted, audited mutations — cheap, local, and visible where they land."
        result="The document in your Library, the line on the Activity sub-tab, and the timer counting down in the corner widget. All three are files or rows you can go look at."
      >
        <.prompt text="Save that plan as a document called weekend-projects, note in my journal that the deck order shipped, and remind me in 45 minutes to check the oven." />
        <ol class="ic-unfold">
          <li>
            <code>document_save</code> writes <code>weekend-projects</code> into your
            Library — markdown on disk, yours, greppable.
          </li>
          <li>
            <code>journal_append</code> adds a line to today's record (the Activity
            sub-tab, live and read-only).
          </li>
          <li>
            <code>notify_create</code> sets a 45-minute timer — it chimes from the
            corner widget, snooze and dismiss included.
          </li>
        </ol>
      </.example>

      <%!-- Cycle 2 was "The market at a glance" (finance_quote/news/fundamentals/
            filings) until 08-08, when the operator called it: trading is not part
            of what Explore teaches any more. The finance_* commands still exist and
            are still on /cmd-list — they simply stopped being one of the six things
            the atlas puts in front of a first-time user. The notebook replaced it
            because it carries a better lesson: two write verbs that look alike and
            are not interchangeable, and a concurrency rule you can actually hit. --%>
      <.example
        n={2}
        title="The notebook and the vault"
        want="Two places to put words, and they are not the same place."
        needs="Nothing. The notebook is local Markdown in your workspace."
        touches="Searches and reads your notes, then writes one. `note_save` overwrites a whole note; `note_create` makes a new one."
        confirm="No gate, but a real guard on overwrites: `note_save` requires the revision that `note_read` returned. Changed underneath and the save is refused with the current revision instead of quietly winning."
        result="A note on the Notes tab, greppable Markdown on disk. A stale revision comes back as a refusal you can re-read and merge, not as lost writing."
      >
        <.prompt text="Find my note about the launch checklist, add the two things we settled today, and start a fresh note for the follow-ups." />
        <ol class="ic-unfold">
          <li>
            <code>note_search</code>
            finds it by title or body; <code>note_read</code>
            returns the note <span class="font-semibold text-base-content">and a revision</span>.
          </li>
          <li>
            <code>note_save</code> hands that revision back with the new body. If the
            file moved on since — you edited it in the Notes tab, another run touched
            it — the save is refused rather than clobbering you. Last writer does not
            win by default.
          </li>
          <li>
            <code>note_create</code>
            starts the follow-ups note. Note the split worth
            remembering: notes are <span class="font-semibold text-base-content">your</span>
            writing, and the agent only creates one when you asked for a note. Its own
            findings and reports go to the Library with <code>document_save</code>
            — different place, different verb, on purpose.
          </li>
          <li>
            Every note verb is restricted, including <code>note_list</code>: your note
            titles are your private writing, so even listing them is not safe-tier.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="The phone desk"
        want="Voicemail triage and a quick text back, from the same chat."
        needs="Messages in the archive for the reads. The text needs outbound SMS configured and explicitly switched on — off by default."
        touches="Reads the phone log; clears one message's unheard flag; sends a real, unrecallable text."
        confirm="`sms_send` is policy-gated — an untrusted-provenance run is blocked and files a pending approval. The reads are safe-tier and `phone_mark_heard` is an explicit verb rather than a side effect of reading."
        result="Transcripts in chat, the light cleared on that one message, the text in its thread. With SMS not enabled the send refuses outright — it never half-sends."
      >
        <.prompt text="Any voicemails since yesterday? Mark the one from Dana heard, and text her: on my way." />
        <ol class="ic-unfold">
          <li>
            <code>phone_list</code> pulls recent messages — transcripts included —
            and <code>phone_mark_heard</code> clears Dana's.
          </li>
          <li>
            <code>sms_send</code> is the sharp one: gated, disabled until you've
            explicitly configured outbound SMS, and capped per recipient per day.
            Until it's switched on, the command refuses safely — it never
            half-sends.
          </li>
        </ol>
        <p class="text-sm leading-relaxed text-base-content/70">
          The phone line has its own tutorial in this rail — the trust rules are
          where the real content is.
        </p>
      </.example>

      <.example
        n={4}
        title="Web errands, hands off the wheel"
        want="Fetch, search, file — without touching the browser tab."
        needs="Network access. No browser tab, no desktop app, no login."
        touches="Fetches a public page through an SSRF-guarded fetch, then writes a Library document and a bookmark locally."
        confirm="None. The guard here is not a confirmation but the fetch itself: it refuses to be pointed at private or loopback addresses."
        result="A saved copy in your Library and the address bookmarked. A blocked or unreachable URL fails on the fetch, before anything is filed."
      >
        <.prompt text="Find the Tauri 2.8 release notes, save a copy to my library, and bookmark the page." />
        <ol class="ic-unfold">
          <li>
            <code>web_search</code> finds it; <code>browser_fetch</code> pulls the
            page through an SSRF-guarded fetch — no visible browser involved.
          </li>
          <li>
            <code>document_save</code> files the copy; <code>bookmark_add</code> keeps the address.
          </li>
          <li>
            Driving the <span class="italic">real</span> browser — clicking,
            filling, watching it happen — is its own discipline: that's the
            BrowserControl tab in this rail.
          </li>
        </ol>
      </.example>

      <.example
        n={5}
        title="The queue is the desk"
        want="Durable work items, not chat scrollback."
        needs="Nothing to enqueue. The recall half only has something to find once you have run work worth remembering."
        touches="Adds a durable item to the queue and reads past run summaries. Claiming and completing items moves them through the queue."
        confirm="None — the queue is a worklist, and adding to it is the cheap end. What an item is allowed to DO when an agent works it is governed by that run's own tier and gates."
        result="The item survives a restart, an agent swap, everything short of you deleting it. `memory_search` with no history returns nothing rather than inventing a recollection."
      >
        <.prompt text="Add 'renew the domain before Friday' to the queue — and didn't we already deal with a DNS thing last month? What did we do?" />
        <ol class="ic-unfold">
          <li>
            <code>dispatch_enqueue</code> files the item durably — it survives a
            restart, an agent swap, anything short of you deleting it.
          </li>
          <li>
            <code>memory_search</code> answers the second half from past run
            summaries — what was actually done, not what you half-remember.
          </li>
          <li>
            <code>dispatch_list</code>, <code>dispatch_claim</code>, <code>dispatch_done</code>
            are the worklist verbs; the unattended
            version of this loop is the Gmail/GWS tab's cycle 4.
          </li>
        </ol>
      </.example>

      <.example
        n={6}
        title="It learns your routines"
        want="Repeated sequences become skills — with your sign-off."
        needs="Enough command history to have a repeated sequence in it. On a fresh install there is nothing to find yet."
        touches="Reads your command history and files suggestions. Approving one writes a new enabled skill file into your workspace."
        confirm="`skill_suggestion_approve` is gated: an untrusted-provenance run cannot approve a skill, and approval files a pending request instead. Turning a sequence into a one-liner is exactly as consequential as it sounds."
        result="A skill file on disk you can read and edit, and the sequence available as one command. Nothing is enabled until you approve it — suggestions just sit there."
      >
        <.prompt text="Anything I keep doing by hand that you could turn into a one-liner?" />
        <ol class="ic-unfold">
          <li>
            <code>skill_analyze</code> scans command history for repeated sequences
            and files suggestions; <code>skill_suggestions</code> lists what's
            pending.
          </li>
          <li>
            Approval is yours and it's gated: <code>skill_suggestion_approve</code>
            writes the enabled skill file — after that, the whole sequence is one
            command.
          </li>
        </ol>
      </.example>

      <.link
        navigate="/cmd-list"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Browse the full command list
      </.link>
    </div>
    """
  end
end
