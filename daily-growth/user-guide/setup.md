# Setup

## Day 1 — the wizard (~5 min)

When the app first opens, the setup wizard walks you through:

1. **You** — your name/org (used to label what you create).
2. **Workspace folder** — where Buster Claw keeps everything (default
   `~/Desktop/BusterClawCLI`). This folder is the heart of the app.
3. **Google Workspace** — connect Gmail/Calendar via OAuth (also available later
   under **Settings → Google Workspace**).

On first launch Buster Claw seeds a starter `job-descriptions/mail-triage.md`, a
roster `README.md`, and a `memory/trusted-email-senders.md` template.

## The one thing you MUST configure

**Edit `memory/trusted-email-senders.md`.** This is the gate: Buster Claw only
puts email on the agent's plate if the sender is listed here (everything else is
still archived to the Library, just never actioned). Open it (the in-app
**Workspace** file browser, or any editor) and add entries:

    - you@yourrealdomain.com
    - *@yourcompany.com        # whole-domain wildcard

The seeded template trusts **nobody** by default — until you add someone, nothing
gets queued. That is intentional and safe.
