# 06-13-26 Roadmap — Hyper-minimal first-run onboarding

Goal: a new user goes from first launch to **doing remote agentic work through
their email** in **four dotted steps**, with copy that is never wordy, jargony,
or intimidating. The flow replaces today's `/setup` wizard and auto-launches on
first run.

Decisions locked with the operator:

- **Google connect is the one allowed exception** to the no-jargon rule — Google
  owns the OAuth consent flow, so we keep it as clean as possible but accept its
  inherent friction. Everything else must feel effortless.
- **Install covers both CLIs** — auto-place the `buster-claw` launcher, then
  actively guide the Claude Code install (the agent the user runs in the
  terminal).
- **Replace `/setup`** with the new minimal dotted flow, and **auto-launch it
  full-screen on first run** (today's wizard never auto-shows).
- **Go-live opens the terminal with `./buster-claw mailman poll` pre-typed**; the
  user presses enter.

---

## The flow — welcome + 4 dots

A welcome line (explainer, not a dot) then four steps. Each dot's filled/empty
state is **computed from real state** (extends the existing
`BusterClaw.Setup.status/0` pattern), so progress survives reloads and partial
completion always shows.

```
   Buster Claw runs your email and web tasks for you.
   Four quick steps to go live.            [ Get started ]

        ●━━━━━●━━━━━○━━━━━○
     Workspace  Tools  Email  Go live
```

1. **Pick your folder** — "Where your assistant keeps its files." Show the
   default `~/Desktop/BusterClawCLI`, a `Use this folder` button, and a `Change…`
   link. Done when `workspace_confirmed = "true"`.
2. **Get the tools ready** — "Your assistant runs as Claude Code. We'll set it
   up." The `buster-claw` launcher is placed automatically (instant ✓). Then
   detect Claude Code: ✓ if present, else an `Install Claude Code` button runs the
   official installer in the in-app terminal with visible progress, then
   re-detects. Done when the launcher exists **and** an agent CLI is detected.
3. **Connect your email** — "Buster Claw works through your Gmail. This is a
   one-time Google step." The accepted-friction step; reuse the existing OAuth
   flow as-is, calmer copy. **On connect, auto-add the connected address as a
   trusted sender** so going live immediately does something. Done when a Google
   account is connected.
4. **Start working** — "Open the terminal and press enter — your assistant starts
   watching your inbox. Email yourself a task to try it." `Open terminal` →
   `/terminal` with `./buster-claw mailman poll` pre-typed. Done when a poll/shift
   is active.

**Dropped from the path:** the current `:identity` (name/org) step — not needed
to go live. It moves to the Settings page (`put_profile` stays).

---

## Work items

### A. `lib/buster_claw/setup.ex` — recompute progress as 4 steps

Replace the three tracked steps (`:profile, :workspace, :google`) with four:

- `:workspace` — `workspace_complete?/0` (exists; `workspace_confirmed == "true"`).
- `:tools` — new `tools_complete?/0`: `WorkspaceCLI.launcher_path/0` exists on
  disk **and** an agent CLI is detected
  (`System.find_executable("claude") || System.find_executable("codex")`).
- `:google` — `google_complete?/0` (exists).
- `:live` — new `live_complete?/0`: a poll/shift is active. Use
  `BusterClaw.Orchestration.active_shift/0 != nil` as the primary signal; if we
  want to credit a bare `mailman poll` with no shift, also accept a recent
  Dispatch poll heartbeat (decide during build — `active_shift` is the simplest
  reliable signal and is what "go on duty" already sets).

Keep `put_profile/3`, `profile_name/0`, `profile_org/0` for the Settings page;
just stop counting profile as an onboarding step.

### B. `lib/buster_claw_web/live/setup_live.ex` — rebuild as the dotted flow

- New step list `[:welcome, :workspace, :tools, :google, :live]` (welcome =
  explainer; the four after are the dots).
- Render a **4-dot progress indicator** driven by `Setup.status/0` (filled /
  current / empty). Add a small reusable dots component (inline or in
  `core_components.ex`).
- Strip the `:identity` step and its `save_profile` UI from this view.
- De-jargon every label/blurb per the copy above. Short sentences. No "OAuth",
  "PATH", "PTY", "escript" in user-facing text.
- **Tools step:** call `WorkspaceCLI.ensure/0` on entry; show ✓. Detect the agent
  CLI; if missing, an `Install Claude Code` action opens the terminal and runs the
  official installer (see D), then re-checks detection.
- **Google step:** reuse the existing `connect_google` / auth-url handlers. On a
  successful connect, also `TrustedSenders.add_entry(account_email)` (see F).
- **Live step:** `Open terminal` broadcasts a terminal-open request with the
  mailman startup command and `push_navigate` to `/terminal` (see E).
- Mark onboarding complete (`Settings.mark_onboarding_complete/0`) when the user
  reaches/finishes the live step, so the flow doesn't reappear.

### C. First-run auto-launch + skip

- Add an `on_mount` hook (or a thin plug) on the main authenticated routes: if
  `not Settings.onboarding_completed?/0`, redirect to `/setup`. Exclude `/setup`
  itself and the Google OAuth callback route so the flow and its sign-in can run.
- Provide a visible `Skip for now` link in the flow that exits to `/` without
  marking complete (home keeps its existing "Finish setup" CTA for re-entry).

### D. Guided Claude Code install

- Detect with `System.find_executable("claude")` (treat `codex` as an
  alternative agent).
- Install path: run the **official Claude Code installer in the in-app terminal**
  (visible, no elevated-permission surprises) rather than a backend Port. Confirm
  the canonical install command from current Claude Code docs before wiring it;
  re-run detection when the user returns to the Tools step.

### E. Terminal pre-type plumbing

- Reuse `BusterClaw.TerminalWorkspace` PubSub + `TerminalCommands` (mailman role
  already defaults to `./buster-claw mailman poll`) to request a tab that opens
  with that command pre-filled. Confirm `terminal_live.ex` honors a startup
  command from the queued request; the user presses enter to run it.

### F. Trusted-sender smart default

- On successful Google connect, `TrustedSenders.add_entry/1` with the connected
  account's own address, so the user's own email is trusted out of the box and
  step 4 produces a real Dispatch item on the first test email.

### G. Tests

- `test/buster_claw/setup_test.exs` — 4-step status computation; each completion
  predicate (`tools_complete?`, `live_complete?`) true/false transitions.
- LiveView test — first-run redirect to `/setup`; dots fill as underlying state
  changes; live step issues the terminal-open broadcast.
- Trusted-sender auto-add on Google connect.

---

## Smoke test (signifies completion)

Run on a clean profile (fresh DB, or clear the `onboarding_completed_at` /
`workspace_confirmed` settings, remove the workspace `buster-claw` launcher, and
disconnect Google).

1. **Launch the app.** Onboarding appears full-screen automatically, four empty
   dots.
2. **Workspace.** Click `Use this folder` → dot 1 fills.
3. **Tools.** `buster-claw` shows ✓ immediately. If Claude Code is missing, click
   `Install Claude Code`, watch it install in the terminal, return → ✓ → dot 2
   fills.
4. **Email.** Connect a real Gmail and complete Google sign-in → the account
   shows connected; confirm your own address was auto-added to
   `memory/trusted-email-senders.md` → dot 3 fills.
5. **Go live.** Click `Open terminal` → the terminal opens with
   `./buster-claw mailman poll` pre-typed → press enter → polling starts → dot 4
   fills and onboarding marks complete.
6. **Prove the loop.** From your own (now-trusted) address, email yourself a
   task. Within a poll cycle a Dispatch item appears (`shift/Dispatch.md` fridge /
   `./buster-claw dispatch list`).
7. **Relaunch the app.** Onboarding does **not** reappear; home shows normal
   status with no "Finish setup" CTA.

**Pass = all four dots fill, the terminal polls, the test email becomes a
Dispatch item, and onboarding stays gone on relaunch.** Plus `mix precommit`
green.
