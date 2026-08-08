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

      <.example
        n={2}
        title="The market at a glance"
        want="Quotes, news and filings — without opening a single site."
      >
        <.prompt text="What's NVDA doing today, and is there any news worth my time?" />
        <ol class="ic-unfold">
          <li>
            <code>finance_quote</code>
            and <code>finance_news</code>
            — both reads, both safe-tier, answered straight into chat.
          </li>
          <li>
            Deeper digging is the same shape: <code>finance_fundamentals</code>
            and <code>finance_filings</code>
            when you ask "why". Every figure carries
            its source and an as-of; none of it is transcribed by the model.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="The phone desk"
        want="Voicemail triage and a quick text back, from the same chat."
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
      </.example>

      <.example
        n={4}
        title="Web errands, hands off the wheel"
        want="Fetch, search, file — without touching the browser tab."
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

      <.example n={5} title="The queue is the desk" want="Durable work items, not chat scrollback.">
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
