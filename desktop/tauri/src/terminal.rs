//! PTY-backed terminal sessions for the in-app Terminal tab.
//!
//! Each session spawns the user's `$SHELL` in a pseudo-terminal via
//! `portable-pty`. A reader thread streams PTY output to the webview as
//! `terminal:data:<id>` events; the webview (xterm.js) sends keystrokes back
//! through `terminal_input`. Rendering/scrollback/colors are all handled by
//! xterm.js — this side is just the PTY plumbing.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use rand::distributions::Alphanumeric;
use rand::Rng;
use tauri::{AppHandle, Emitter, Manager, State};

// Keep a bounded tail of recent PTY output per session so the webview can
// reattach (after a tab switch unmounts/remounts the view) and replay it.
const MAX_SCROLLBACK: usize = 256 * 1024;

pub struct Session {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    writer: Box<dyn Write + Send>,
    scrollback: Arc<Mutex<Vec<u8>>>,
}

#[derive(Default)]
pub struct TerminalState {
    sessions: Mutex<HashMap<String, Session>>,
}

fn new_id() -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(12)
        .map(char::from)
        .collect()
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string())
}

fn pty_size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

#[tauri::command]
pub fn terminal_open(
    app: AppHandle,
    state: State<TerminalState>,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
) -> Result<String, String> {
    let pair = native_pty_system()
        .openpty(pty_size(cols, rows))
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut cmd = CommandBuilder::new(default_shell());
    // Run as a login shell (`-l`) so the user's profile (~/.zprofile, ~/.zshrc,
    // etc.) is sourced — exactly how Terminal.app and iTerm launch shells. A GUI
    // app launched from Finder inherits a minimal PATH, so without this, tools
    // installed via Homebrew, npm-global, or version managers (nvm/fnm/asdf) —
    // including `node`, which many CLIs shell out to — aren't found.
    cmd.arg("-l");
    // Open in the Buster Claw workspace folder when the frontend passes one and it
    // exists; otherwise fall back to the user's home directory.
    let start_dir = cwd
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
        .or_else(dirs::home_dir);
    if let Some(dir) = start_dir {
        cmd.cwd(dir);
    }
    // GUI-launched processes lack these; real terminal emulators set them, and
    // many TUIs need a UTF-8 locale and truecolor hint to render correctly.
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    if std::env::var_os("LANG").is_none() {
        cmd.env("LANG", "en_US.UTF-8");
    }
    // Point the in-app `./buster-claw` CLI at this app's server + token. The
    // packaged release sets these in the process env (main.rs); in dev they come
    // from `.env`. Without them the CLI defaults to :4000 with no token and can't
    // reach the running app.
    for key in ["BUSTER_CLAW_URL", "BUSTER_CLAW_API_TOKEN"] {
        if let Some(val) = std::env::var_os(key) {
            cmd.env(key, val);
        }
    }

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("failed to spawn shell: {e}"))?;

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("failed to clone pty reader: {e}"))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|e| format!("failed to take pty writer: {e}"))?;

    // Drop the slave handle so the PTY tears down cleanly when the shell exits.
    drop(pair.slave);

    let id = new_id();
    let data_event = format!("terminal:data:{id}");
    let exit_event = format!("terminal:exit:{id}");
    let reader_app = app.clone();
    let reader_id = id.clone();
    let scrollback = Arc::new(Mutex::new(Vec::new()));
    let reader_scrollback = Arc::clone(&scrollback);

    // Insert the session BEFORE spawning the reader. An instant shell EOF makes
    // the reader remove `reader_id` from the map; if that removal raced ahead of
    // this insert it would leave a dead Session behind. Inserting first means the
    // reader either finds and removes a real entry or (already-removed) no-ops.
    state
        .sessions
        .lock()
        .map_err(|e| format!("terminal state lock poisoned: {e}"))?
        .insert(
            id.clone(),
            Session {
                master: pair.master,
                child,
                writer,
                scrollback,
            },
        );

    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        // A multi-byte UTF-8 sequence (box-drawing glyphs, emoji — both heavily
        // used by TUIs like Claude Code) can straddle a read boundary. Decoding
        // each 4 KB chunk independently would turn the split bytes into `�` and
        // throw off cell widths, so hold back any incomplete trailing sequence
        // and prepend it to the next read.
        let mut carry: Vec<u8> = Vec::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    // Scrollback keeps the raw byte stream; it is decoded lossily
                    // only when replayed on reattach.
                    if let Ok(mut sb) = reader_scrollback.lock() {
                        sb.extend_from_slice(&buf[..n]);
                        if sb.len() > MAX_SCROLLBACK {
                            let overflow = sb.len() - MAX_SCROLLBACK;
                            sb.drain(0..overflow);
                        }
                    }

                    carry.extend_from_slice(&buf[..n]);
                    // Emit the longest valid UTF-8 prefix; keep only a genuinely
                    // incomplete trailing sequence for the next read. Invalid
                    // bytes mid-stream are flushed lossily so the stream can't
                    // wedge.
                    let emit_upto = match std::str::from_utf8(&carry) {
                        Ok(_) => carry.len(),
                        Err(e) => match e.error_len() {
                            None => e.valid_up_to(),
                            Some(_) => carry.len(),
                        },
                    };

                    if emit_upto > 0 {
                        let chunk = String::from_utf8_lossy(&carry[..emit_upto]).to_string();
                        carry.drain(0..emit_upto);
                        let _ = reader_app.emit(&data_event, chunk);
                    }
                }
                Err(_) => break,
            }
        }

        let _ = reader_app.emit(&exit_event, ());
        if let Some(state) = reader_app.try_state::<TerminalState>() {
            if let Ok(mut sessions) = state.sessions.lock() {
                sessions.remove(&reader_id);
            }
        }
    });

    Ok(id)
}

/// Reattach to an existing session: returns its buffered scrollback so the
/// webview can replay it, or `None` if the session is gone (shell exited).
#[tauri::command]
pub fn terminal_attach(state: State<TerminalState>, id: String) -> Result<Option<String>, String> {
    let sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("terminal state lock poisoned: {e}"))?;

    match sessions.get(&id) {
        None => Ok(None),
        Some(session) => {
            let sb = session
                .scrollback
                .lock()
                .map_err(|e| format!("scrollback lock poisoned: {e}"))?;
            Ok(Some(String::from_utf8_lossy(&sb).to_string()))
        }
    }
}

#[tauri::command]
pub fn terminal_input(state: State<TerminalState>, id: String, data: String) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("terminal state lock poisoned: {e}"))?;
    let session = sessions
        .get_mut(&id)
        .ok_or_else(|| "no such terminal session".to_string())?;
    session
        .writer
        .write_all(data.as_bytes())
        .map_err(|e| format!("terminal write failed: {e}"))?;
    session
        .writer
        .flush()
        .map_err(|e| format!("terminal flush failed: {e}"))
}

#[tauri::command]
pub fn terminal_resize(
    state: State<TerminalState>,
    id: String,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    let sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("terminal state lock poisoned: {e}"))?;
    let session = sessions
        .get(&id)
        .ok_or_else(|| "no such terminal session".to_string())?;
    session
        .master
        .resize(pty_size(cols, rows))
        .map_err(|e| format!("terminal resize failed: {e}"))
}

/// Whether the terminal has a foreground process other than its own shell — a
/// build, a long-running command, or a live agent (Claude Code / Codex) session.
///
/// Reads the PTY master's foreground process-group id (`tcgetpgrp`, surfaced by
/// portable-pty as `process_group_leader`) and compares it to the shell's own
/// pid. The shell is the session/group leader of its PTY, so when it sits at the
/// prompt the foreground pgid equals its pid → idle. A different foreground pgid
/// means a child has the terminal → busy. The webview uses this to confirm
/// before closing a tab that would kill running work; an idle terminal closes
/// silently. Returns `false` on any unknown/closed-fd case so a dead terminal is
/// never treated as busy.
#[tauri::command]
pub fn terminal_busy(state: State<TerminalState>, id: String) -> Result<bool, String> {
    let sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("terminal state lock poisoned: {e}"))?;
    let Some(session) = sessions.get(&id) else {
        return Ok(false);
    };
    let busy = match (
        session.master.process_group_leader(),
        session.child.process_id(),
    ) {
        (Some(fg_pgid), Some(shell_pid)) => i64::from(fg_pgid) != i64::from(shell_pid),
        _ => false,
    };
    Ok(busy)
}

#[tauri::command]
pub fn terminal_close(state: State<TerminalState>, id: String) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|e| format!("terminal state lock poisoned: {e}"))?;
    if let Some(mut session) = sessions.remove(&id) {
        let _ = session.child.kill();
    }
    Ok(())
}

/// Kill every live terminal child. Called on app exit.
pub fn shutdown_all(app: &AppHandle) {
    if let Some(state) = app.try_state::<TerminalState>() {
        if let Ok(mut sessions) = state.sessions.lock() {
            for (_, mut session) in sessions.drain() {
                let _ = session.child.kill();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_id_is_twelve_alphanumerics_and_unique() {
        let a = new_id();
        let b = new_id();
        assert_eq!(a.len(), 12);
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric()));
        // 62^12 ids: a collision here means the generator is broken, not unlucky.
        assert_ne!(a, b);
    }

    #[test]
    fn default_shell_honours_env_and_falls_back_absolute() {
        let shell = default_shell();
        assert!(shell.starts_with('/'), "shell must be absolute: {shell}");
        match std::env::var("SHELL") {
            Ok(env_shell) => assert_eq!(shell, env_shell),
            Err(_) => assert_eq!(shell, "/bin/zsh"),
        }
    }

    #[test]
    fn pty_size_maps_dims_and_zeroes_pixels() {
        let size = pty_size(120, 40);
        assert_eq!(size.cols, 120);
        assert_eq!(size.rows, 40);
        assert_eq!(size.pixel_width, 0);
        assert_eq!(size.pixel_height, 0);
    }
}
