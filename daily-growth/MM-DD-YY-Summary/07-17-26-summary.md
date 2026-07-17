# 07-17-2026 Summary

Started as a one-fix day — the workspace desktop-drop from 07-15 didn't work in
the packaged app — then turned into a phone-tab pass: retired the rotary dial,
switched the Playback shader to mandelbrot, and built a per-voicemail Twilio cost
feature that, priced against the real data, upended the assumption that started
it.

## OS file drop: Tauri's native event, not HTML5 (`6438c55`)

The 07-15 version disabled Tauri's native drag-drop (`dragDropEnabled:false`) so
the browser DOM would receive the drop and a LiveView upload could consume it.
That trick is **Windows-only** — the tauri-utils source says so in as many words.
On macOS, WKWebView refuses to hand file *contents* to JavaScript on an OS drop,
so `dataTransfer.files` came back empty and nothing imported. The operator
restarted the shell (so the config change was live) and still saw nothing appear.

Reverted the config and switched to Tauri's native `tauri://drag-drop` event,
which delivers file **paths** rather than contents. The `WorkspaceDropzone` hook
now pushes the dropped paths to the server, and `FileManager.import_file` copies
each into the folder in view **by path** — efficient (no byte re-read) and the
correct primitive for local files. The HTML5 path stays only as a plain-browser
dev fallback; the two never both fire (native in Tauri, DOM in a browser).

**The symlink wrinkle, handled.** The operator's workspace root is a symlink to
a Desktop folder. Copying by path is exactly right for that: the OS follows the
link on write, and `FileManager.within?` already canonicalizes symlinks per
component so the containment guard still passes. `import_file` also learned to
copy a dropped **folder** recursively (`cp_r`). New tests cover the symlinked
destination and the folder-drop; operator-verified in the desktop app after a
restart.

**The lesson worth keeping:** Tauri's `dragDropEnabled:false` HTML5 route is
Windows-only. On macOS, use the native `tauri://drag-drop` event and copy by
path.

## Phone tab: rotary dial retired, Playback goes mandelbrot (`4a87206`)

Removed the decorative rotary dial (the SVG component, geometry, `dial_digit`/
`dial_clear` handlers, and the `RotaryDial` hook + `rotary_dial.js`). It looked
great but wrote a check the backend can't cash — it implied outbound calling
BusterPhone doesn't have. The Playback panel now rests on a plain "select a
message to play it here" placeholder. Same commit switches that panel's shader
from `waves` to `mandelbrot` (`shader_bg` took a shader name; only Playback
changed).

## Per-voicemail Twilio cost — and the number was a surprise (`4a59121`)

Built the whole cost path: `Telephony.Twilio` (a REST client shared with future
SMS) prices a voicemail from its RecordingSid alone — the Recording resource
hands back the parent `call_sid`, so no edge-function change or extra storage was
needed (I'd started down that road and reverted it). Cost sums recording + call
leg + transcription(s) into micro-USD; because Twilio prices populate
asynchronously, it's a retryable back-fill (`refresh_unpriced_costs`) riding the
drain tick, provisional until final. The `/phone` UI shows a per-message chip, a
call/rec/txt breakdown in the detail (sub-cent precision so the call leg reads
`$0.0085`, not a rounded `$0.01`), a running total, and a manual refresh. Creds
read from `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` in the Mac's gitignored
`.env`.

**The surprise:** priced live against all 8 real voicemails, each is **$0.0525**
— recording $0.0025 + transcription $0.05, with the inbound **call leg `null`**
(trial-credit calls never per-call price). So the motivating "20–30¢ per message"
was high by ~5×; the real per-message resource cost is a nickel, and
**transcription is 95% of it**. The one-line lever to cut it is dropping
`transcribe="true"` in the edge function (→ ~a quarter-cent). That null call leg
also caught a bug: it would have pinned trial rows "pricing…" forever and re-hit
Twilio every tick — so `final?` now gates on recording + transcription only.

## State of the tree

`mix precommit` green — **1031 tests**, 0 failures — plus 78 bun tests. The day's
four commits (OS-drop fix, cost engine, phone-tab UI, this summary) are on main.
`.env` holds the Twilio creds and stays untracked.
