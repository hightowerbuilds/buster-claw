//! PTY-backed terminal sessions for the in-app Terminal tab.
//!
//! Each session spawns the user's `$SHELL` in a pseudo-terminal via
//! `portable-pty`. A reader thread streams PTY output to the webview as
//! `terminal:data:<id>` events; the webview (xterm.js) sends keystrokes back
//! through `terminal_input`. Rendering/scrollback/colors are all handled by
//! xterm.js — this side is just the PTY plumbing.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Mutex;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use rand::distributions::Alphanumeric;
use rand::Rng;
use tauri::{AppHandle, Emitter, Manager, State};

pub struct Session {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    writer: Box<dyn Write + Send>,
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
) -> Result<String, String> {
    let pair = native_pty_system()
        .openpty(pty_size(cols, rows))
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut cmd = CommandBuilder::new(default_shell());
    if let Some(home) = dirs::home_dir() {
        cmd.cwd(home);
    }
    cmd.env("TERM", "xterm-256color");

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

    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = String::from_utf8_lossy(&buf[..n]).to_string();
                    let _ = reader_app.emit(&data_event, chunk);
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
            },
        );

    Ok(id)
}

#[tauri::command]
pub fn terminal_input(
    state: State<TerminalState>,
    id: String,
    data: String,
) -> Result<(), String> {
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
