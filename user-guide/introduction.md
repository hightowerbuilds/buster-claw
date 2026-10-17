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

The sidebar opens panels in your Work Area, with Browser and Settings as separate tabs:

- **Work area** — the main screen: panels you open from the sidebar and
  arrange as you like. **Chat** (talk to your agent), **Workspace** (the file
  browser), **Notes**, **Calendar**, **Terminal**, **Pockets**
  (your own folders of media — the background pool, the dock icon),
  **Explained** (guided tours of each feature), and **Activity** (the one log
  of what your agent did).
- **Browser** — a real browser your agent can drive, not just a reader. It works
  the tab you are looking at, and Agent Mode runs longer errands in their own
  window with a payment gate that stops before money moves.
- **Settings** — seven tabs: **Appearance**, **Notify**, **Agents & models**,
  **Google Workspace**, **Credentials**, **Speech**, and **Security**. Which model
  runs where is on **Agents & models**; connecting Google is on **Google
  Workspace**; **Speech** chooses the macOS voice and speed for reading chat
  replies aloud in the desktop app. Notification sound routing stays in
  **Notify**, and the app's version and build are at the foot of **Security**.

**Security** (the last Settings tab, or `/security` directly) is the **Sentinel
audit feed**: every command that changes something, every outbound send, and
every untrusted fetch is logged there. Plain reads are not, so the feed stays
legible.

Choose **Grid** to arrange panels in tiles, or **Overlap** to move them freely
by their headers. Clicking a covered panel brings it forward. Each mode keeps
its arrangement, and each Work Area remembers its own mode. On a narrow screen,
panels stack vertically until there is room to move them again.

Each Work Area holds **four panels**. Opening another creates and selects
**Work Area 2**, then **Work Area 3**, and so on. Selecting an already open
panel returns to its area. The Terminal button or **Command-T** creates another
terminal; in Browser, Command-T creates a browser tab. **Command-1** returns to
your last Work Area, **Command-2** to Settings, and **Command-3** to Browser.

In Overlap, focus a panel heading and use the arrow keys to move it, Enter to
save, or Escape to cancel. **Reset positions** restores the starting arrangement.
Closing a secondary Work Area closes its terminals, asking first if work is
running. The first Work Area stays available.

Tabs appear across the top. Drag to reorder; hold Alt while dropping one tab
onto another to join them into a side-by-side split. Two Work Areas cannot be
joined together.

Everything the agent creates lives under your **workspace folder**: `library/`
(archived docs), `memory/`, `jobs/` (the jobs it can run), and `Dispatch.md` —
your live worklist, at the workspace root. Machine bookkeeping lives out of the
way in `.buster-claw/`.
