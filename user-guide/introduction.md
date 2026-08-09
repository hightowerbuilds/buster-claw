# Introduction

## The mental model

**Buster Claw is the environment around an AI agent you run yourself.** You run
**Claude Code, Codex, or OpenCode on your own subscription** — in a terminal
*inside the app*, or headlessly from the app's own Chat tab. Buster Claw does
not need its own API key. Its job is to:

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
until you stand down, which means running **`./buster-claw off-duty`**. Ctrl-C
stops the polling you can see; it does not end the shift.

> `on-duty` is the consolidated front door — it replaced the older
> `mailman poll` and `shift run` commands, which no longer exist.

## What's in the app

The dock at the bottom switches between five surfaces:

- **Home** — the main screen, with its own row of sub-tabs: **Chat** (talk to
  your agent), **Notes** (your Markdown notebook), **Calendar**, **Phone**
  (BusterPhone's message machine), **Studio** (sound editing), **Explore**
  (guided tours of each feature), and **Activity** (the one log of what your
  agent did).
- **Workspace** — file browser for everything Buster Claw keeps (your
  trusted-senders list, the jobs roster, the Library archive).
- **Browser** — a real browser your agent can drive, not just a reader. It works
  the tab you are looking at, and Agent Mode runs longer errands in their own
  window with a payment gate that stops before money moves.
- **Terminal** — your agent's shell, inside the app. `/split` puts two panes
  side by side.
- **Settings** — Google Workspace, models and harnesses, appearance, and the
  rest of the configuration.

A few surfaces have no dock button and are reached by link or URL — most
importantly **Security** (`/security`), the **Sentinel audit feed**: every
command that changes something, every outbound send, and every untrusted fetch
is logged there. Plain reads are not, so the feed stays legible.

Everything the agent creates lives under your **workspace folder**: `library/`
(archived docs), `memory/`, `jobs/` (the jobs it can run), and `Dispatch.md` —
your live worklist, at the workspace root. Machine bookkeeping lives out of the
way in `.buster-claw/`.
