defmodule BusterClawWeb.Explore.Gws do
  @moduledoc """
  The Gmail / Google Workspace tutorial — four prompt-your-way cycles from a
  cold connect to a working mail-and-calendar loop.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explore.Shared

  # The Gmail/GWS tutorial: four prompt-your-way cycles, each showing what the
  # user literally types and how it unfolds command-by-command. Every command
  # named here is real — checked against the catalog and `cli.ex` when written
  # (08-02); if a command is renamed, this copy is part of the rename.
  def gws_panel(assigns) do
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
          Connect Google —
          <.link
            navigate="/settings"
            class="font-semibold text-primary hover:opacity-80"
          >
            Configuration → Google Workspace
          </.link>
          — with the bundled button when this build provides it, or Advanced setup
          with your own OAuth client. Everything below happens in the home <span class="font-semibold text-base-content">Chat</span>. You type plain
          English; the agent picks the commands. You never memorize a command name,
          but they are shown here so you can see exactly what your words turn into.
          Mutations, triggers, and policy decisions land on the <.link
            navigate="/security"
            class="font-semibold text-primary hover:opacity-80"
          >
            Security feed
          </.link>; ordinary reads are intentionally omitted to keep that feed useful.
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
            Mail from a sender on your trusted list is also auto-filed into the
            Dispatch queue as work. Other mail is still synced and archived in the
            Library, but it is not enqueued for an agent.
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
            and flags. Search and read are safe-tier reads; the two sync commands
            are safe-tier triggers that update the local Library and Calendar and
            are audited. None of them sends mail or changes Google data.
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
            Now — and only now — <code>gmail_send</code>. It is a restricted mutation
            with two controls: the command refuses without <code>confirm_send</code>,
            and its policy-level <span class="font-semibold text-base-content">gated</span>
            flag blocks untrusted-origin runs and files a pending approval. Successful
            sends are audited on the Security feed.
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
            <code>dispatch_reply</code>
            sends a threaded Gmail reply back to your
            phone and marks the item done — the full loop, unattended. It is a
            restricted, audited mutation, but it has no separate <code>confirm_send</code>
            argument and is not policy-gated; trusting the
            sender and starting an on-duty shift are the controls for this path.
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
            Sharing has a command-specific guard: <code>drive_share</code> refuses
            unless <code>confirm_share</code> is explicitly true. It is a restricted,
            audited mutation, but it is not a policy-gated command and does not
            create a pending approval by itself.
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
            You read the draft, you say go — <code>gmail_send</code>
            with <code>confirm_send</code>, policy-gated and audited, attachment and all.
          </li>
        </ol>
      </.example>

      <p class="text-sm leading-relaxed text-base-content/70">
        The pattern in all six: <span class="font-semibold text-base-content">say the
          outcome, then inspect the actual control</span>. A policy gate, a required
        confirmation argument, and a trusted unattended workflow are different
        mechanisms. “Show me before you send” is useful intent, but the enforced
        stop is the command's real guard — <code>confirm_send</code>, <code>confirm_share</code>, or a pending policy approval — not the wording
        alone.
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
end
