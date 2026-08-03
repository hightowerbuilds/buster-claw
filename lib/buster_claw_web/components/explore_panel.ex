defmodule BusterClawWeb.ExplorePanel do
  @moduledoc """
  The home Explore tab: guided tours of Buster Claw, one surface at a time.

  Presentation only — `select_explore_tab` is handled by the parent LiveView
  (`StatusLive`), which owns the sub-tab assign for the usual home-tab reason:
  the panel renders behind `:if`, so state kept here would not survive a glance
  at Chat.

  The Intro is a launcher: a grid of square tiles, one per sub-tab. Adding a
  tab is one edit in this file — a `@stubs` entry (or a bespoke panel function
  plus a `@tabs` line for the two site tabs). The rail, the Intro grid, the
  parent's event whitelist (via `tab_keys/0`), and the panel dispatch all read
  from the same registries.
  """
  use BusterClawWeb, :html

  @site_url "https://busterclaw.lol"
  @ntf_url "https://notesthatfloat.com"

  # Feature sub-tabs: rail + tile metadata for every non-site tab. A key in
  # @built has its own tutorial panel below; the rest render the generic stub
  # (a true paragraph, a deep link, an honest "tutorial in the works" line)
  # until Phase 2 replaces them, one tab at a time.
  @features [
    %{
      key: "shaders",
      label: "Shaders & Backgrounds",
      eyebrow: "Ambiance",
      blurb: "The live WGSL smoke behind the homepage — and how to swap it.",
      body:
        "The homepage background is a real WGSL shader, compiled live in the " <>
          "webview. Drop a .wgsl file into your workspace and it hot-swaps — no " <>
          "rebuild. Backgrounds, images, and the rest of the app's look live on " <>
          "the Appearance tab.",
      path: "/appearance",
      path_label: "Open Appearance"
    },
    %{
      key: "phone",
      label: "BusterPhone",
      eyebrow: "The phone line",
      blurb: "An answering machine and SMS relay your agent works for you.",
      body:
        "Your agent gets its own number. Voice greets callers, records, " <>
          "transcribes, and files the message into the Library; texts from " <>
          "trusted numbers land in triage for the agent to work. The Phone tab " <>
          "is the switchboard — messages, recordings, and the activity feed.",
      path: "/phone",
      path_label: "Open the Phone tab"
    },
    %{
      key: "browser",
      label: "BrowserControl",
      eyebrow: "Hands on the web",
      blurb: "A real browser the agent drives — the tab you're looking at.",
      body:
        "Not a headless scraper: the agent reads and acts inside the same " <>
          "logged-in tab you see — browser_read, browser_click, browser_fill — " <>
          "with Agent Mode for longer errands and a payment gate that halts " <>
          "before money moves.",
      path: "/browse",
      path_label: "Open the browser"
    },
    %{
      key: "cmd",
      label: "Command List",
      eyebrow: "The surface",
      blurb: "The whole command surface, one worked example at a time.",
      body:
        "Every feature is reachable through one canonical command surface — " <>
          "CLI and HTTP, per-caller trust tiers, every call audited. This " <>
          "tutorial is the atlas: what the families do and what you'd say to " <>
          "use them.",
      path: "/cmd-list",
      path_label: "Open the command list"
    },
    %{
      key: "gws",
      label: "Gmail/GWS",
      eyebrow: "Google Workspace",
      blurb: "Connect once; the agent reads and acts on mail, calendar, files.",
      body:
        "One-click connect, then sync and act on Gmail, Calendar, Drive, Docs, " <>
          "and Contacts. Senders on your trusted list can even enqueue work for " <>
          "the agent just by emailing you.",
      path: "/settings",
      path_label: "Open Configuration"
    },
    %{
      key: "trading",
      label: "Trading",
      eyebrow: "The desk",
      blurb: "Robinhood, read-first: connect once, confirm every order yourself.",
      body:
        "The Trading tab is a market desk run through your own Claude CLI — " <>
          "balances, cost-basis P&L, charts, earnings. The app never holds " <>
          "your broker credentials, and nothing trades without your click.",
      path: "/trading",
      path_label: "Open the Trading tab"
    }
  ]

  # Feature tabs whose tutorial panel exists — everything else stubs.
  @built ~w(gws cmd browser trading)

  # {key, rail label}, in rail order. Intro leads, the two site tabs follow,
  # then the feature tabs in @features order.
  @tabs [{"intro", "Intro"}, {"site", "BusterClaw.lol"}, {"ntf", "NTF"}] ++
          Enum.map(@features, &{&1.key, &1.label})

  # Intro-grid tiles: the two site tabs, then the stubs. Grid order = rail order.
  @tiles [
           %{
             key: "site",
             label: "BusterClaw.lol",
             eyebrow: "Headquarters",
             blurb: "Where the app lives — and where your agent's number comes from."
           },
           %{
             key: "ntf",
             label: "Notes That Float",
             eyebrow: "From the same bench",
             blurb: "The operator's notebook on the open web."
           }
         ] ++ Enum.map(@features, &Map.take(&1, [:key, :label, :eyebrow, :blurb]))

  @doc "Sub-tab keys, in rail order — the parent's `select_explore_tab` whitelist."
  def tab_keys, do: Enum.map(@tabs, &elem(&1, 0))

  attr :tab, :string, required: true

  def explore_panel(assigns) do
    assigns =
      assign(assigns, tabs: @tabs, stubs: Enum.reject(@features, &(&1.key in @built)))

    ~H"""
    <section
      id="home-explore"
      class="ic-panel ic-scanlines flex min-h-0 flex-1 flex-col overflow-hidden"
    >
      <div
        role="tablist"
        aria-label="Explore"
        class="flex shrink-0 flex-wrap gap-1 border-b-2 border-base-content/20 px-2 pt-2"
      >
        <button
          :for={{key, label} <- @tabs}
          type="button"
          role="tab"
          aria-selected={to_string(@tab == key)}
          phx-click="select_explore_tab"
          phx-value-tab={key}
          class={[
            "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
            if(@tab == key,
              do: "border-primary text-primary",
              else: "border-transparent text-base-content/55 hover:text-base-content"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <.intro_panel :if={@tab == "intro"} />
        <.site_panel :if={@tab == "site"} />
        <.ntf_panel :if={@tab == "ntf"} />
        <.gws_panel :if={@tab == "gws"} />
        <.cmd_panel :if={@tab == "cmd"} />
        <.browser_panel :if={@tab == "browser"} />
        <.trading_panel :if={@tab == "trading"} />
        <.stub_panel :for={stub <- @stubs} :if={@tab == stub.key} stub={stub} />
      </div>
    </section>
    """
  end

  # The opening tab is a launcher: what Explore is for, then a grid of square
  # tiles — one per sub-tab, in rail order. A tile fires the same
  # `select_explore_tab` event as the rail; the content lives on the tab it
  # opens, so nothing here duplicates a panel.
  defp intro_panel(assigns) do
    assigns = assign(assigns, :tiles, @tiles)

    ~H"""
    <div class="mx-auto flex max-w-3xl flex-col gap-6 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Explore</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Learn the machine.
        </h2>
      </div>

      <p class="text-sm leading-relaxed text-base-content/80">
        Buster Claw is a lot of surfaces — a browser the agent can drive, a phone
        line, Google Workspace, a live shader on this very page. Each square below
        opens a short tour of one of them: what it does, how to drive it yourself,
        and how to hand it to the agent. The grid grows as tutorials are written.
      </p>

      <%!-- The 3-step onboarding, moved here from the Settings Get Started tab
            (08-02) — setup before sightseeing. A native <details>, closed by
            default: returning users see one quiet row, first-run users open it
            once. State is the browser's, not LiveView's — a re-render that
            collapses it just restores the default. --%>
      <details id="explore-get-started" class="group ic-panel overflow-hidden">
        <summary class="ic-collapse-summary">
          <div>
            <p class="ic-eyebrow">Get started</p>
            <p class="mt-1 text-sm text-base-content/65">
              Three steps and you're talking to Buster Claw.
            </p>
          </div>
          <.icon
            name="hero-chevron-down"
            class="size-4 shrink-0 text-base-content/50 transition group-open:rotate-180"
          />
        </summary>

        <ol class="flex flex-col gap-4 border-t-2 border-base-content/20 px-5 py-5">
          <li class="flex gap-3">
            <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
              1
            </span>
            <div class="min-w-0">
              <h3 class="font-semibold">Download &amp; install Claude Code</h3>
              <p class="mt-0.5 text-sm text-base-content/65">
                Buster Claw has no built-in AI — it drives your own Claude Code CLI
                headlessly. Install it once with
                <.copy_command command="brew install --cask claude-code" />, then
                sign in (<span class="font-mono">claude</span> in a terminal).
              </p>
            </div>
          </li>

          <li class="flex gap-3">
            <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
              2
            </span>
            <div class="min-w-0">
              <h3 class="font-semibold">Chat with Buster Claw</h3>
              <p class="mt-0.5 text-sm text-base-content/65">
                Use the Chat sub-tab, right next to this one. Ask it to triage your
                inbox, draft a reply, or look something up — it runs headless Claude
                for you, no terminal needed.
              </p>
            </div>
          </li>

          <li class="flex gap-3">
            <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
              3
            </span>
            <div class="min-w-0">
              <h3 class="font-semibold">Set up communications</h3>
              <p class="mt-0.5 text-sm text-base-content/65">
                Connect Google Workspace in
                <.link navigate="/settings" class="font-semibold text-primary hover:opacity-80">
                  Configuration
                </.link>
                (one click), then list your trusted senders in Contacts — the corner
                widget on this screen; mail from anyone else is ignored. When you're
                ready, give your agent its own phone line on the
                <.link navigate="/phone" class="font-semibold text-primary hover:opacity-80">
                  Phone
                </.link>
                tab.
              </p>
            </div>
          </li>
        </ol>
      </details>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        <button
          :for={tile <- @tiles}
          type="button"
          phx-click="select_explore_tab"
          phx-value-tab={tile.key}
          class="ic-panel flex aspect-square flex-col justify-between p-4 text-left transition hover:-translate-y-0.5 hover:border-primary"
        >
          <p class="ic-eyebrow">{tile.eyebrow}</p>
          <div class="flex flex-col gap-1.5">
            <p class="font-display text-sm font-black uppercase tracking-wide">
              {tile.label}
            </p>
            <p class="text-xs leading-relaxed text-base-content/65">{tile.blurb}</p>
          </div>
        </button>
      </div>
    </div>
    """
  end

  # busterclaw.lol — headquarters, and the counter where the one purchasable
  # asset (the agent's phone number) is bought. The copy describes what the
  # site *is*, not a store that isn't live yet; revisit when vending opens.
  defp site_panel(assigns) do
    assigns = assign(assigns, :site_url, @site_url)

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Headquarters</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          busterclaw.lol
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          <span class="font-semibold text-base-content">busterclaw.lol</span>
          is where the app lives on the web — releases, docs, and the counter where
          your agent gets its own phone number.
        </p>
        <p>
          The number is the one thing you buy: a real line, issued to you, one
          bill. It's what the whole machine is ultimately for — an agent that can
          answer when the world calls.
        </p>
      </div>

      <.external_link url={@site_url} label="Open busterclaw.lol" />
    </div>
    """
  end

  defp ntf_panel(assigns) do
    assigns = assign(assigns, :ntf_url, @ntf_url)

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
      <div>
        <p class="ic-eyebrow">From the same bench</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Notes That Float
        </h2>
      </div>

      <p class="text-sm leading-relaxed text-base-content/80">
        <span class="font-semibold text-base-content">Notes That Float</span>
        is a separate notebook that lives on the open web — writing and experiments
        from the operator, outside this app.
      </p>

      <.external_link url={@ntf_url} label="Open notesthatfloat.com" />
    </div>
    """
  end

  attr :stub, :map, required: true

  # A feature tab before its tutorial exists: a true paragraph about the
  # surface, a deep link into the real tab, and an honest note that the
  # walkthrough is still being written. Phase 2 replaces these one at a time.
  defp stub_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
      <div>
        <p class="ic-eyebrow">{@stub.eyebrow}</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          {@stub.label}
        </h2>
      </div>

      <p class="text-sm leading-relaxed text-base-content/80">{@stub.body}</p>

      <.link
        navigate={@stub.path}
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" />
        {@stub.path_label}
      </.link>

      <p class="font-mono text-xs uppercase tracking-wide text-base-content/45">
        Tutorial in the works — the full walkthrough lands on this tab.
      </p>
    </div>
    """
  end

  # The Gmail/GWS tutorial: four prompt-your-way cycles, each showing what the
  # user literally types and how it unfolds command-by-command. Every command
  # named here is real — checked against the catalog and `cli.ex` when written
  # (08-02); if a command is renamed, this copy is part of the rename.
  defp gws_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Google Workspace</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Prompting your way to a working mail-and-calendar cycle
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          Connect Google once —
          <.link
            navigate="/settings"
            class="font-semibold text-primary hover:opacity-80"
          >
            Configuration → Google Workspace
          </.link>
          — and everything below happens in
          the home <span class="font-semibold text-base-content">Chat</span>. You type
          plain English; the agent picks the commands. You never memorize a command
          name — but they're shown here so you can see exactly what your words turn
          into, and every call lands on the <.link
            navigate="/security"
            class="font-semibold text-primary hover:opacity-80"
          >
            Security feed
          </.link>.
        </p>
      </div>

      <.example
        n={1}
        title="The morning brief"
        want="You're busy. You want the day handed to you, not fished for."
      >
        <.prompt text="Good morning — sync my mail and calendar, then brief me: what's on today, which emails actually need a reply from me, and anything that smells urgent." />
        <ol class="ic-unfold">
          <li>
            The agent runs <code>gmail_sync</code> — your latest mail lands in the app.
            Anything from a sender on your trusted list is auto-filed into the Dispatch
            queue as work.
          </li>
          <li>
            Then <code>google_calendar_sync</code> — today's events sync one-way into
            the app calendar (glance at the Calendar sub-tab any time).
          </li>
          <li>
            Then <code>gmail_search</code>
            over recent unread and <code>gmail_read</code>
            on the candidates.
          </li>
          <li>
            You get the brief in chat: the schedule, a short needs-your-reply list,
            and flags. Nothing left your machine — these are all safe-tier reads.
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Draft, don't send"
        want="Inbox triage in your voice — with your hand still on the send button."
      >
        <.prompt text="Go through the unread. Anything that needs an answer, draft a reply in my voice — short, warm, direct. Show me all of them here. Send nothing." />
        <ol class="ic-unfold">
          <li>
            <code>gmail_read</code> per thread, then <code>gmail_draft_create</code> —
            the drafts sit in your real Gmail Drafts folder, and the agent shows them
            in chat.
          </li>
          <li>
            You read them and answer like a person:
            <span class="italic">"Send the one to Dana as-is. On the second, propose
              Thursday instead, then send."</span>
          </li>
          <li>
            Now — and only now — <code>gmail_send</code>. Sending is a
            <span class="font-semibold text-base-content">gated</span>
            command: it's
            outbound, so it's always audited, and an agent working untrusted content
            can't fire it at all — the attempt is refused and queued for your
            approval instead of silently dropped.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="Remember the schedule"
        want="Your calendar should interrupt you, not wait to be read."
      >
        <.prompt text="Sync my calendar, then set reminders 30 minutes before each meeting today — make it an hour for anything off-site." />
        <ol class="ic-unfold">
          <li><code>google_calendar_sync</code>, then the agent reads today's events.</li>
          <li>
            One <code>notify_create</code> per meeting, timed per your rule.
          </li>
          <li>
            The reminders line up in the corner widget's
            <span class="font-semibold text-base-content">Notify</span>
            tab; each one
            chimes when due, and snooze/dismiss are right there.
          </li>
        </ol>
      </.example>

      <.example
        n={4}
        title="The unattended cycle"
        want="You're out. The assistant answers your email about your own day."
      >
        <p class="text-sm leading-relaxed text-base-content/80">
          One-time setup: add your own phone's email address to
          <span class="font-semibold text-base-content">Trusted Senders</span>
          (Contacts, in the corner widget), then in the terminal: <code>./buster-claw on-duty</code>.
        </p>
        <.prompt
          label="You email — from your phone, hours later"
          text="Subject: Afternoon check. What's between 1 and 6? Anything I should prep for the 3pm?"
        />
        <ol class="ic-unfold">
          <li>
            On-duty polls your trusted mail; your email auto-enqueues as a Dispatch
            item — durable work, not a fleeting chat message.
          </li>
          <li>
            The Dispatcher engages the agent on the item: it syncs the calendar,
            reads the 3pm's details, and writes the rundown.
          </li>
          <li>
            <code>dispatch_reply</code> sends a threaded Gmail reply back to your
            phone and marks the item done — the full loop, unattended.
          </li>
          <li>
            Stand down with <code>./buster-claw off-duty</code>. A <code>STOP</code>
            file kills the shift instantly, and a hard budget cap stops it rather
            than burning tokens.
          </li>
        </ol>
      </.example>

      <.example
        n={5}
        title="Make the files, not just the mail"
        want="The deliverable is a sheet or a deck — so have the agent build it where it lives."
      >
        <.prompt text="Pull the amounts out of this week's receipt emails into a new expenses sheet, and turn Monday's agenda into a short slide deck. Put both in a Drive folder called Ops, then share the folder with Dana as a writer." />
        <ol class="ic-unfold">
          <li>
            <code>gmail_search</code> and <code>gmail_read</code> dig out the receipts.
          </li>
          <li>
            <code>sheets_create</code>, then <code>sheets_append_values</code>
            row by
            row — a real spreadsheet in your Drive, not a text blob in chat. (Docs
            work the same way: <code>docs_create</code>; decks: <code>slides_create</code>
            then <code>slides_batch_update</code>, slide
            by slide.)
          </li>
          <li>
            <code>drive_folder_create</code>
            makes Ops; <code>drive_update</code>
            files both into it. Anything already on your disk goes up with <code>drive_upload</code>
            — a workspace file straight into Drive.
          </li>
          <li>
            Sharing is its own gate: <code>drive_share</code> can email the grantee,
            so it requires an explicit confirmation — the agent holds and asks you
            before Dana gets access.
          </li>
        </ol>
      </.example>

      <.example
        n={6}
        title="Send the file, not a link"
        want="Some people want the attachment. Attach it."
      >
        <.prompt text="Email Dana the expenses sheet as an .xlsx — subject 'Ops expenses', two lines of context in the body, file attached. Show me before it goes." />
        <ol class="ic-unfold">
          <li>
            <code>drive_export</code> pulls the sheet down as <code>.xlsx</code> into
            your workspace.
          </li>
          <li>
            <code>gmail_draft_create</code>
            with the file on its <code>attachments</code>
            — any workspace file rides along: exports,
            downloads, things the agent wrote itself.
          </li>
          <li>
            You read the draft, you say go — <code>gmail_send</code>, gated and
            audited as ever, attachment and all.
          </li>
        </ol>
      </.example>

      <p class="text-sm leading-relaxed text-base-content/70">
        The pattern in all six: <span class="font-semibold text-base-content">say the
          outcome, not the commands</span> — and let the gates do their job. Reads
        are free; anything outbound — a send, a share — is gated and audited. When
        in doubt, end a prompt with "show me before you send" — the agent will hold
        there.
      </p>

      <.link
        navigate="/settings"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Connect Google Workspace
      </.link>
    </div>
    """
  end

  # The Command List tutorial: the atlas of the command surface. Anatomy first
  # (read / mutate / gated), then the funnel diagram, then one worked example
  # per non-GWS family — Gmail/Drive belong to the Gmail/GWS tab and deep
  # browser driving to BrowserControl, so this page stays deliberately light on
  # both. Command names checked against the catalog when written (08-02); the
  # test asserts each still exists.
  defp cmd_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The surface</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          One command surface — a guided atlas
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          Everything Buster Claw can do — every tab, every feature — is reachable
          through one canonical set of 150+ commands. You don't memorize them:
          you say outcomes in Chat and the agent picks the commands. But knowing
          the shape of the surface makes you a sharper driver, and that's this
          page. The live, complete list is on <.link
            navigate="/cmd-list"
            class="font-semibold text-primary hover:opacity-80"
          >
            Cmd List
          </.link>.
        </p>
        <p>Every command is one of three kinds, and the kind tells you the stakes:</p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">read</span> — looks at
            things. Safe to fire, nothing changes, nothing leaves the machine.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">mutate</span> — changes
            state. Restricted to trusted callers, always audited.
          </li>
          <li>
            <span class="font-mono font-bold text-primary">gated</span> — outbound or
            irreversible: sends, shares, deletes. An agent working untrusted content
            can't fire these at all — the refusal is queued for your approval, never
            silently dropped.
          </li>
        </ul>
      </div>

      <figure class="flex flex-col gap-2">
        <svg
          viewBox="0 0 560 300"
          role="img"
          aria-label="Chat, terminal, and trusted email all funnel through one command surface, past policy tiers and gates, out to the app's surfaces — and every mutation lands on the Sentinel audit feed."
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
            <text x="280" y="108" font-size="8">150+ COMMANDS</text>
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
            <text x="280" y="134">POLICY</text>
            <text x="280" y="145">TIERS · GATES</text>
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
            EVERY MUTATION
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
          funnels through the same choke point. Nothing mutating skips the <.link
            navigate="/security"
            class="font-semibold text-primary hover:opacity-80"
          >
            feed
          </.link>.
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
            <code>journal_append</code> adds a line to today's record (the Notes
            sub-tab, live).
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
        want="Quotes, news, and your own history — without opening a single site."
      >
        <.prompt text="What's NVDA doing today, any news worth my time, and how has the portfolio done this month?" />
        <ol class="ic-unfold">
          <li>
            <code>finance_quote</code>, <code>finance_news</code>, <code>portfolio_history</code>
            — all reads, all safe-tier, answered
            straight into chat.
          </li>
          <li>
            Deeper digging is the same shape: <code>finance_fundamentals</code>
            and <code>finance_filings</code>
            when you ask "why". The full desk lives on
            the Trading tab.
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

  # The BrowserControl tutorial. The load-bearing concept is *where the agent's
  # hands are* — the live tab, the ephemeral sandbox, or the Agent Mode window —
  # so the diagram comes before the cycles. The commerce cycle states the current
  # posture deliberately: the human pays; the agent cannot pay and cannot
  # confirm a purchase (browser-closeout roadmap owns revisiting that). Command
  # names checked against the catalog when written (08-02); the test asserts
  # each still exists.
  defp browser_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Hands on the web</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          BrowserControl — a real browser, driven on the record
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          Not a headless scraper. The agent can work
          <span class="font-semibold text-base-content">the tab you are looking
            at</span>
          — your live, logged-in session, while you watch — and every
          read and every click lands on the
          <.link navigate="/security" class="font-semibold text-primary hover:opacity-80">
            Security feed
          </.link>
          with what it targeted and how it matched. The first thing to learn is
          where the agent's hands can be, because there are three answers:
        </p>
      </div>

      <figure class="flex flex-col gap-2">
        <svg
          viewBox="0 0 560 240"
          role="img"
          aria-label="The agent can drive three surfaces: your live tab, which is logged in, watched, and audited; an ephemeral sandbox tab with no cookies that forgets everything, the default for new tabs; and the Agent Mode window, its own Chromium with a frozen scope and a payment gate."
          class="w-full text-base-content/70"
        >
          <defs>
            <marker
              id="bc-arrow"
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

          <rect
            x="14"
            y="92"
            width="110"
            height="52"
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
          />
          <g class="font-mono" fill="currentColor" font-size="10" text-anchor="middle">
            <text x="69" y="114" font-weight="bold">THE AGENT</text>
            <text x="69" y="128" font-size="8">ONE COMMAND SURFACE</text>
          </g>

          <g stroke="currentColor" stroke-width="1.5" marker-end="url(#bc-arrow)">
            <line x1="124" y1="104" x2="208" y2="52" />
            <line x1="124" y1="118" x2="208" y2="118" />
            <line x1="124" y1="132" x2="208" y2="184" />
          </g>

          <g fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="212" y="26" width="150" height="48" />
            <rect x="212" y="94" width="150" height="48" />
            <rect x="212" y="162" width="150" height="48" />
          </g>
          <g class="font-mono" fill="currentColor" font-size="10" text-anchor="middle">
            <text x="287" y="46" font-weight="bold">YOUR LIVE TAB</text>
            <text x="287" y="60" font-size="8">LOGGED IN · YOU WATCH</text>
            <text x="287" y="114" font-weight="bold">SANDBOX TAB</text>
            <text x="287" y="128" font-size="8">NO COOKIES · FORGETS</text>
            <text x="287" y="182" font-weight="bold">AGENT WINDOW</text>
            <text x="287" y="196" font-size="8">OWN CHROMIUM · SCOPE FROZEN</text>
          </g>

          <g class="font-mono" fill="currentColor" font-size="8">
            <text x="380" y="42">browser_read · click · fill —</text>
            <text x="380" y="53">audited, session and all</text>
            <text x="380" y="110">the DEFAULT for new tabs</text>
            <text x="380" y="121">(session: "user" is opt-in)</text>
            <text x="380" y="178">agent mode: off-scope halts,</text>
            <text x="380" y="189" fill="var(--color-primary)">payment gate: the human pays</text>
          </g>
        </svg>
        <figcaption class="text-xs leading-relaxed text-base-content/60">
          Live-tab and sandbox verbs need the desktop app open; the Agent window and
          background checks run on your installed Chromium.
        </figcaption>
      </figure>

      <.example
        n={1}
        title="Read over my shoulder"
        want="You're on the page. Let the agent do the reading."
      >
        <.prompt text="What am I looking at? Summarize the important parts of this thread and file a copy in my library." />
        <ol class="ic-unfold">
          <li>
            <code>browser_current</code>
            names the tab (URL + title); <code>browser_read</code>
            takes the rendered page — visible text and
            links, exactly as your logged-in session sees it.
          </li>
          <li>
            <code>browser_capture_page</code> files it: a markdown artifact in your
            Library plus a screenshot in the workspace. (<code>browser_screenshot</code> alone when you just want the picture.)
          </li>
          <li>
            The summary arrives in chat; the reads are on the feed. Nothing was
            clicked, nothing left the machine.
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Do the clicking"
        want="Same tab, but now the agent acts — while you watch it happen."
      >
        <.prompt text="On this page, open the Pricing tab and put my work email into the newsletter box. Don't submit anything." />
        <ol class="ic-unfold">
          <li>
            <code>browser_find_elements</code> lists the page's visible interactive
            elements as an indexed registry — links, buttons, inputs, each with a
            label.
          </li>
          <li>
            <code>browser_click</code> hits Pricing (by index, CSS selector, or
            visible text — exact match before substring, and an ambiguous match is
            refused rather than guessed at); <code>browser_fill</code> types the
            email, firing real input events.
          </li>
          <li>
            One rule to know: navigation invalidates the index registry —
            after the page changes, the agent runs <code>browser_find_elements</code>
            again instead of clicking stale
            numbers.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="A fresh tab that forgets"
        want="Some errands shouldn't ride your session at all."
      >
        <.prompt text="Open the Stripe docs in a clean tab and find the webhook signature section — don't use my logins for this." />
        <ol class="ic-unfold">
          <li>
            <code>browser_open_tab</code> opens it — and by default that tab is an
            ephemeral sandbox: no cookies, nothing saved, excluded from restore.
            Riding your real session is opt-in, never the default.
          </li>
          <li>
            <code>browser_wait</code>
            lets the page settle (a missed condition
            returns <code>matched: false</code>, not an error); <code>browser_extract</code>
            pulls the section, whole-page or by CSS
            selector.
          </li>
        </ol>
      </.example>

      <.example
        n={4}
        title="Turn a routine into a check"
        want="Anything you check weekly, the agent can check on demand — and remember the history."
      >
        <.prompt text="I keep checking whether the venue's booking page still shows Saturday slots. Make that a saved check I can run any time." />
        <ol class="ic-unfold">
          <li>
            The agent composes a <code>browser_flow</code> — navigate, wait, assert,
            extract, up to 25 steps, halting at the first failure with a per-step
            report.
          </li>
          <li>
            <code>browser_check_save</code>
            names it and stores it as markdown in <code>checks/</code>
            in your workspace, with an append-only run history.
          </li>
          <li>
            From then on: "run the venue check" → <code>browser_check_run</code>.
            Saved on the background engine, it runs headless on your installed
            Chromium — the desktop app doesn't even need to be open. <code>browser_check_list</code>
            shows every check and its last result.
          </li>
        </ol>
      </.example>

      <.example
        n={5}
        title="The long errand — Agent Mode"
        want="A multi-step task in its own window, with the sharpest gate in the app."
      >
        <.prompt text="Find the drain pump part number for my dishwasher (model in my notes), find a store that has it, and put one in a cart. I'll pay." />
        <ol class="ic-unfold">
          <li>
            <code>agent_run_start</code> with <code>commerce: true</code> opens a
            separate, headful window of your installed Chromium. The run's scope is
            frozen from your intent — <code>agent_run_navigate</code> outside the
            allowlist comes back <code>halted</code>, not quietly followed.
          </li>
          <li>
            <code>agent_run_act</code>
            does the stepwork — click, fill, extract —
            and what comes back is egress-prepared: policy-filtered and redacted,
            never raw page dumps. You can watch the window live from the <.link
              navigate="/browse"
              class="font-semibold text-primary hover:opacity-80"
            >
              browse tab
            </.link>.
          </li>
          <li>
            <code>agent_run_cart</code>
            pins what's being bought — name, unit price,
            quantity — and the moment a payment page appears, the run hands off:
            cart frozen, agent stopped.
            <span class="font-semibold text-base-content">You pay, in the real
              window. The agent cannot pay and cannot confirm a purchase.</span>
          </li>
          <li>
            Afterwards: <code>agent_run_resume</code> puts it back to work if
            there's more to do; <code>agent_run_finish</code> ends a completed
            errand as <code>done</code>. (<code>agent_run_stop</code> exists too —
            that means halted, not finished, and the trajectory stays inspectable.)
          </li>
        </ol>
      </.example>

      <p class="text-sm leading-relaxed text-base-content/70">
        If any of this misbehaves, one diagnostic proves the whole engine end to
        end: ask for a probe and the agent runs <code>browser_control_probe</code>
        — detect, launch, navigate, read back,
        exit — and reports the failing step by name instead of laundering it.
      </p>

      <.link
        navigate="/browse"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open the browser
      </.link>
    </div>
    """
  end

  # The Trading tutorial — deliberately the simple one: how to connect
  # Robinhood, then a plain can/can't split. Source of truth is the
  # `Trading`/`TradingOrder` moduledocs; the connect commands mirror what the
  # Trading tab itself shows on first run. No cycles here — the surface's
  # whole pitch is restraint, and the page should read that way too.
  defp trading_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The desk</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Trading — Robinhood, read-first
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          The
          <.link navigate="/trading" class="font-semibold text-primary hover:opacity-80">
            Trading tab
          </.link>
          is a market desk: balances across your accounts, positions with real
          cost-basis P&amp;L, charts, earnings, and a chat that can talk it all
          through. Everything runs through
          <span class="font-semibold text-base-content">your own Claude CLI</span>
          —
          Buster Claw never holds your Robinhood credentials, and account numbers
          are masked to their last four digits and never stored.
        </p>
      </div>

      <div class="ic-panel flex flex-col gap-3 p-4">
        <p class="ic-eyebrow">Connect — once, in a terminal</p>
        <div class="flex flex-col gap-2">
          <.command_block command="claude mcp add --transport http --scope user robinhood https://agent.robinhood.com/mcp/trading" />
          <.command_block command="claude mcp login robinhood" />
        </div>
        <p class="text-sm leading-relaxed text-base-content/70">
          The login opens Robinhood's own OAuth page in your browser; the tokens
          land in your Mac's Keychain and every trading turn reuses them silently
          after that. If the tools still report unavailable after logging in, run
          <code class="font-semibold">claude mcp logout robinhood</code>
          and log in
          again — a known Claude Code quirk, not a Buster Claw setting.
        </p>
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <div class="ic-panel flex flex-col gap-2 p-4">
          <p class="ic-eyebrow">What it can do</p>
          <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
            <li>
              Read your accounts: balances, positions with tax-lot cost basis,
              order history, quotes, charts, and the earnings calendar — the
              dashboard is built from these reads.
            </li>
            <li>
              Talk markets in the trading chat: "how has my cost basis on AAPL
              changed this year?" is a question, not a risk.
            </li>
            <li>
              <span class="font-semibold text-base-content">Propose</span> an
              order: ask it to buy or sell and it gathers side, symbol, quantity,
              and price into a typed confirm card — showing you exactly what
              would be submitted.
            </li>
          </ul>
        </div>

        <div class="ic-panel flex flex-col gap-2 p-4">
          <p class="ic-eyebrow">What it can't do</p>
          <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
            <li>
              Place, amend, or cancel an order on its own. The chat's tool list
              is read-only by construction — an order submits only when
              <span class="font-semibold text-base-content">you</span>
              click the
              confirm card, and only to the one account Robinhood marks as
              Agentic. Every other account stays read-only.
            </li>
            <li>
              Retry an uncertain submit. If a run dies before the broker's answer
              arrives, it reports unknown and tells you to check Robinhood — it
              never re-sends an order.
            </li>
            <li>
              See your password. The OAuth handshake is between you and
              Robinhood; Buster Claw only ever borrows the Keychain tokens.
            </li>
          </ul>
        </div>
      </div>

      <p class="text-sm leading-relaxed text-base-content/70">
        The quiet risk cap: only the Agentic account can ever transact, so what
        you fund it with is the most an order can touch.
      </p>

      <.link
        navigate="/trading"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open the Trading tab
      </.link>
    </div>
    """
  end

  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :want, :string, required: true
  slot :inner_block, required: true

  # One worked walkthrough: number + name, the itch it scratches, then the
  # prompt and its unfolding (the caller's inner block). Shared by every
  # tutorial panel — this is the tutorial template, in component form.
  defp example(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 border-l-2 border-base-content/20 pl-4">
      <div>
        <p class="ic-eyebrow">Cycle {@n}</p>
        <h3 class="mt-1 font-display text-base font-black uppercase tracking-wide">
          {@title}
        </h3>
        <p class="mt-1 text-sm italic text-base-content/60">{@want}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :text, :string, required: true
  attr :label, :string, default: "You type"

  # What the user literally says — set apart so the eye can skim a tutorial
  # prompt-first, which is how people actually read these.
  defp prompt(assigns) do
    ~H"""
    <figure class="ic-panel flex flex-col gap-1 p-3">
      <figcaption class="ic-eyebrow">{@label}</figcaption>
      <blockquote class="font-mono text-sm leading-relaxed">“{@text}”</blockquote>
    </figure>
    """
  end

  attr :command, :string, required: true

  # Block-level shell command: wraps rather than scrolling (long commands must
  # never demand horizontal scrolling — operator, 08-02), full-contrast mono on
  # a bordered field, copy button via the global data-terminal-command-copy
  # listener in globals.js.
  defp command_block(assigns) do
    ~H"""
    <div class="flex items-start gap-2 rounded-xs border-2 border-base-content/25 bg-base-200 p-3">
      <code class="min-w-0 flex-1 whitespace-pre-wrap break-all font-mono text-[0.8rem] font-semibold leading-relaxed">
        {@command}
      </code>
      <button
        type="button"
        data-terminal-command-copy={@command}
        aria-label={"Copy command: #{@command}"}
        title="Copy"
        class="inline-flex shrink-0 items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3" />
        <span data-terminal-command-copy-label>Copy</span>
      </button>
    </div>
    """
  end

  attr :command, :string, required: true

  # Inline shell command with a copy button (the click handler is the global
  # data-terminal-command-copy listener in globals.js). Moved here with the
  # 3-step onboarding when GetStartedLive retired (08-02).
  defp copy_command(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 align-middle">
      <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[0.8rem]">{@command}</code>
      <button
        type="button"
        data-terminal-command-copy={@command}
        aria-label={"Copy command: #{@command}"}
        title="Copy"
        class="inline-flex shrink-0 items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3" />
        <span data-terminal-command-copy-label>Copy</span>
      </button>
    </span>
    """
  end

  attr :url, :string, required: true
  attr :label, :string, required: true

  # External sites open in the app's own browser tab — this app has one.
  defp external_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/browse?#{[url: @url]}"}
      class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
    >
      <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
      {@label}
    </.link>
    """
  end
end
