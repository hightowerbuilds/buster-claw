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
