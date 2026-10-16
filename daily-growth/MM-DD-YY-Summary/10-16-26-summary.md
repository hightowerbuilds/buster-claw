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
