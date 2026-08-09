# Setup

## Day 1 — the wizard (~5 min)

When the app first opens, the setup wizard walks you through five steps:

1. **Welcome** — the explainer landing: what Buster Claw is and what emailing it
   gets you. Nothing to fill in. (The four steps below are the ones with dots.)
2. **Workspace folder** — where Buster Claw keeps everything (default
   `~/Desktop/BusterClawCLI`). This folder is the heart of the app.
3. **Tools** — check that a supported agent CLI (`claude`, `codex`, or
   `opencode`) is installed and signed in. Buster Claw has no AI of its own, so
   this is the step that decides whether anything can run at all.
4. **Google Workspace** — connect Gmail/Calendar via OAuth (also available later
   under **Settings → Google Workspace**).
5. **Live** — you're set up; the app hands you off to the Home screen.

On first launch Buster Claw seeds starter jobs in `jobs/` (`mail-triage.md`,
`voicemail-triage.md`, `sms-triage.md`), a roster `README.md`, and the
`memory/trusted-email-senders.md` and `memory/trusted-phone-numbers.md`
templates.

## The one thing you MUST configure

**Edit `memory/trusted-email-senders.md`.** This is the gate: Buster Claw only
puts email on the agent's plate if the sender is listed here (everything else is
still archived to the Library, just never actioned). Open it (the in-app
**Workspace** file browser, or any editor) and add entries:

    - you@yourrealdomain.com
    - *@yourcompany.com        # whole-domain wildcard

The seeded template trusts **nobody** by default — until you add someone, nothing
gets queued. That is intentional and safe.
