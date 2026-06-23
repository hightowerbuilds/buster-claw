# Introduction

## The mental model

**Buster Claw is the environment around an AI agent you run yourself.** You open
a terminal *inside the app* and run **Claude Code (or Codex) there, on your own
subscription** — Buster Claw does not need its own API key. Its job is to:

1. feed that agent work as Markdown files it reads,
2. give it a small CLI to act and report back, and
3. record everything on an audit feed.

Work is **pulled, not pushed**: things land in a queue, and the agent picks them
up when it is ready.

## Going on duty — one command

When you want Buster Claw to start handling mail, open the in-app terminal and
run a single command:

    ./buster-claw on-duty

That puts you **on duty**: it watches Gmail, and as trusted-sender email arrives,
your agent reads each request, does the work through Buster Claw's command
surface, and **replies in-thread** — every step on the audit feed. It stays open
until you stand down: press **Ctrl-C** (or run `./buster-claw off-duty`) to stop.

> `on-duty` is the consolidated front door. The older `mailman poll` and
> `shift run` commands still work, but they now just point you back here.

## What's in the app

The dock at the bottom switches surfaces:

- **Home** — status + today's calendar, and the link to this guide.
- **Terminal / Split** — your agent's workspace; Split puts two panes side by side.
- **Workspace** — file browser for everything Buster Claw keeps (your
  trusted-senders list, job descriptions, the Library archive).
- **Browser** — an in-app reader for fetching/reading web pages (SSRF-guarded).
- **Calendar** — local events.
- **Advanced** — Scheduler, Webhooks/Hooks, Integrations (GitHub/Sentry/Umami),
  Delivery, Memory, and Security.
- **Security** — the **Sentinel audit feed**: every command, outbound send, and
  untrusted fetch is logged here.
- **Settings** — profile, Google Workspace, appearance.

Everything the agent creates lives under your **workspace folder**: `library/`
(archived docs), `memory/`, `job-descriptions/`, `shift/` (your live worklist),
and dated daily-summary folders.
