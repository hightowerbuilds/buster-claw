# 10-16-26 — The chat that vanished

## Morning — one attribute, two panes

| | |
|---|---|
| (first commit) | **The work area's "terminal takes over the screen" bug, found and fixed.** The operator's detail last night: the chat pane disappears the moment the chat starts streaming, and the terminal next to it fills the whole canvas, both panels still open. Reproduced in Chrome on the dev server in two messages. The Workbench hook lays panes out with inline custom properties (`--pane-x/y/width/height`) and marks a narrow canvas `data-stacked`; the server renders neither. LiveView's patch removes any attribute the server did not render, so the first chat token stripped every pane's geometry, the CSS fallbacks sent each one to `0, 0, 100%, 100%`, and the last pane in DOM order — the terminal — landed on top. A MutationObserver watched the `style` attribute go on the same nodes. Fix: `phx-mounted={JS.ignore_attributes(["style", "class"])}` on each pane section and `ignore_attributes(["data-stacked"])` on the canvas, the pattern `duty_live` already used for `<details open>`. Verified in Chrome across three streamed turns; one test guards it and was broken on purpose. |

The focus guard added to `terminal.js` the night before was a guess at this
same report. It was not the cause. It stays: a terminal that attaches while
the operator is mid-sentence elsewhere still should not take the keyboard.

Also this morning: the dev window had died under the phone removal's live
reload (a mid-edit compile error, then the notifications scheduler crashing on a
schema that had vanished under it; the BEAM stayed resident, serving nothing).
Relaunched clean. The fresh boot ran the telephony drop migration and retired
the unedited voicemail brief; the edited SMS brief and the phone-number
template were named and kept.

---

## Morning — the phone operator teardown, as far as a shell can go

| | |
|---|---|
| (second commit, docs) | **Part VI worked.** Read-only inventory of the Twilio account: one number, the local (360) 364-6763 (not the 844 toll-free the memory named), webhooks on the Supabase relay; one messaging service; no subaccounts; the account SID referenced nowhere else on the machine. **busterclaw.lol:** the BusterPhone section, the relay in the stack table, "telephony" in the catalog line, the terms and privacy cross-references and the three `/busterphone/` pages removed and pushed (`buster-website` `3112500`). **Not done, by the agent's fence, not by choice:** the release of the number, the messaging-service delete, the Clinch forgets, the `.env` edit and the token rotation were each refused by the auto-mode classifier (external deletion, secret-store write, irreversible local edit). The Supabase delete is a dashboard action regardless. All six are written as a numbered, ordered checklist in `PHONE_REMOVAL_ROADMAP` Part VI with console paths and the exact curl lines. |

The dev app was left running throughout; nothing here touched :4000.

---

## Mid-morning — the teardown, finished as far as the fence allows

| | |
|---|---|
| (no commit — operator consoles) | Operator: "take your recommendation and follow through." With the go-ahead the shell was allowed through for three of the six: the **BusterPhone messaging service deleted** (204), the **number (360) 364-6763 released** (204, zero numbers left — after Twilio's emergency-address registration had to be detached first and polled to `unregistered`, which took about a minute), and **`.env` cut to the two finance keys**. The Clinch held none of the six phone keys (every delete answered `not_found`: the dev app read them from `.env`). Still refused by the classifier and left to the operator: the **Twilio token rotation** (console → Account → API keys & tokens → request secondary, promote) and the **Supabase project delete** (dashboard, project `tzptdzmwypdmmnmbruke`). |

---

## Late morning — Explained, rewritten

| | |
|---|---|
| (third commit) | **`EXPLAINED_REWRITE_ROADMAP` written and built.** Every tutorial re-read against the app on 10-16: no phone, no dock, a sidebar, a work area of panels, a Clock panel with Contacts and Notify, four terminals, attachments in the mail path. The Intro gained one geography paragraph and every tab after it uses the same words. Sites: busterclaw.lol is the download, the docs and the source — no vending. Gmail/GWS: the Clock panel's Contacts tab, the sidebar's duty dock, `Dispatch.md`, the attachment path, `gmail_attachment_download`. Command List: placements, the Duty page. BrowserControl: the Ask door, `browser_secret_*`, `browser_egress_level`, `browser_download`. Models: Codex threads through its app-server, always. Shaders: the `face` name taught as reserved. Pockets: the orphaned `contact-faces` Pocket (no renderer since the phone left) stops being taught as a surface. Studio: routing keys **rendered from `Notifications.Sound`**, the recording verbs added, every voicemail word gone. The audit test's stale-phrase list grew by ten and **caught five drifts outside the panel on its first run** — two sound descriptions, `note_list`'s description, a `/phone` tab-strip label, and the Duty page's blocker linking to a dead `/phone` route — all fixed in the same commit. |

---

## Afternoon — the code quality sweep, mapped

| | |
|---|---|
| (fourth commit, docs) | **`CODE_QUALITY_SWEEP_10-16-26.md`** — tooling-first inventory of the whole tree: a reference scan (modules and publics with no caller; 82 test-only publics, down from 125 at 09-05), a leftover-word sweep for every removed feature, a suppression census (nothing to remove — 9 credo disables, no skips, no TODOs), a clause-length scan, asset/CSS/script/static/config reference checks, Rust, tests. Findings: the contact-faces stack is orphaned (no renderer since the phone left), two dead shaders, a dead trading config key, 14 digested fonts tracked in git, 16 web-layer `File.*` sites (up from 9), the four frozen files unchanged, two duplicate bodies, `Olympus` arrived 10-12 with no map. Ten phases, deletions first, renames last; five operator questions with defaults. |
