# 07-17-2026 Summary

A one-fix day: the workspace "drag files in from the desktop" feature shipped
07-15 didn't actually work in the packaged app, and this closes that. The other
two workspace pieces from 07-15 (image preview, drag-to-move within the tree)
were fine; only the OS-file drop was broken.

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

## State of the tree

`mix precommit` green — 1016 tests, 0 failures — plus 78 bun tests. Committed and
pushed to main.
