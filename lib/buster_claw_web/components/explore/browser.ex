defmodule BusterClawWeb.Explore.Browser do
  @moduledoc """
  The BrowserControl tutorial — where the agent's hands are (the live tab, the
  ephemeral sandbox, or the Agent Mode window), and the cycles that follow from
  that.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explore.Shared

  # The BrowserControl tutorial. The load-bearing concept is *where the agent's
  # hands are* — the live tab, the ephemeral sandbox, or the Agent Mode window —
  # so the diagram comes before the cycles. The commerce cycle states the current
  # posture deliberately: the human pays; the agent may record the operator's
  # completed purchase but never enters payment itself. Command
  # names checked against the catalog when written (08-02); the test asserts
  # each still exists.
  def browser_panel(assigns) do
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
          — your live, logged-in session, while you watch. Page content sent to an
          agent is policy-filtered and redacted; consequential actions and command
          mutations land on the
          <.link navigate="/security" class="font-semibold text-primary hover:opacity-80">
            Security feed
          </.link>
          with their targets and outcomes. Ordinary reads do not each create a feed
          row. The first thing to learn is where the agent's hands can be, because
          there are three answers:
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
        needs="The desktop app, open, with a page loaded in the browse tab. Live-tab verbs do not exist outside it."
        touches="Reads the rendered page as your logged-in session sees it. Clicks nothing. The capture writes a document to your Library and a screenshot to your workspace."
        confirm="None. Page content handed to an agent is policy-filtered and redacted on the way out; that filtering is the control, not a prompt."
        result="The summary in chat and the capture in your Library. No live tab and the verb tells you so rather than quietly reading something else."
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
        needs="The desktop app and the page you want driven, in front of you."
        touches="Acts inside your real, logged-in session — clicks and typed input are indistinguishable from yours, because they are yours."
        confirm="No per-click confirmation: you are watching, and consequential actions are receipted on the Security feed. The prompt's “don't submit” is instruction, not enforcement — the enforced stop lives in Agent Mode's payment gate, cycle 5."
        result="The page reacts as you watch. An ambiguous target is refused rather than guessed at, and a stale element index after navigation is re-read rather than clicked blind."
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
        needs="The desktop app. No logins — that is the point of this cycle."
        touches="Opens a tab with no cookies and no storage, reads it, and forgets it. Your sessions are not involved and nothing is saved."
        confirm="None needed, because the default is the safe one: a new tab is ephemeral unless someone explicitly opts into your session."
        result="The extracted section in chat; the tab is excluded from restore and leaves nothing behind. A condition that never arrives comes back as unmatched rather than as an error."
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
        needs="Your installed Chromium for the saved run. Composing the flow needs the desktop app; running it later does not."
        touches="Writes a markdown check into your workspace and appends to its run history. The flow itself only navigates, waits, asserts and extracts — it is a read-only recipe."
        confirm="None. A check is deliberately not allowed to be a way to smuggle in clicking: the step vocabulary has no purchase in it."
        result="A file in your workspace's checks folder, runnable by name, with each run's result appended. A flow halts at the first failing step and reports which one — it does not press on."
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
        needs="Your installed Chromium, and a signed-in account on the site if the errand needs one. Commerce runs must be started as commerce runs — the scope is frozen up front."
        touches="Drives a separate browser window through a multi-step errand, and can fill a cart. It cannot pay: no card, no payment fields, no confirmation of payment."
        confirm="The hardest stop in the app, and it is structural rather than a prompt: navigation outside the frozen scope comes back halted, and the moment a payment page appears the cart freezes and the run stops for you."
        result="A filled cart waiting for you in a real window, and a trajectory you can inspect. You pay by hand; the receipt records which of you confirmed it. Off-scope navigation halts visibly instead of wandering."
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
              window. The agent never pays and never holds a card.</span>
            Once you have, either you confirm here or the agent files the receipt
            with <code>agent_run_confirm_purchase</code>
            — every receipt records
            which of you said so.
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
end
