#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rand::distributions::Alphanumeric;
use rand::Rng;
use tauri::{Manager, RunEvent};

mod browser;
mod terminal;
mod voice;
mod workspace;

const APP_DATA_DIR_NAME: &str = "BusterClaw";
// Keychain service under which the master key (SECRET_KEY_BASE) and the loopback
// API tokens are stored. Deliberately independent of the (still-unfinalized)
// bundle identifier so it stays stable across a rename.
const KEYCHAIN_SERVICE: &str = "BusterClaw";
const HEALTH_TIMEOUT: Duration = Duration::from_secs(30);
const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(250);

// Respawn guardrails for the bundled Phoenix release. If the BEAM exits while
// the app is still running, the monitor restarts it with exponential backoff,
// but gives up (and shows error.html) after too many failures in a short window
// to avoid a hot crash-loop.
const RESPAWN_BACKOFF_BASE: Duration = Duration::from_secs(1);
const RESPAWN_BACKOFF_MAX: Duration = Duration::from_secs(30);
const RESPAWN_MAX_RESTARTS: u32 = 5;
const RESPAWN_RESTART_WINDOW: Duration = Duration::from_secs(5 * 60);

/// Everything the release monitor needs to (re)spawn the Phoenix release and
/// transition the webview. Built once in `setup()` and shared with the monitor
/// thread so a respawn re-runs the exact same launch + health-poll + navigate
/// logic as the initial boot.
struct ReleaseLauncher {
    handle: tauri::AppHandle,
    release_child: Arc<Mutex<Option<Child>>>,
    shutting_down: Arc<AtomicBool>,
    release_bin: PathBuf,
    logs_dir: PathBuf,
    database_path: PathBuf,
    workspace_root: PathBuf,
    secret_key_base: String,
    api_token: String,
    mcp_token: String,
    port: u16,
    phoenix_url: String,
}

impl ReleaseLauncher {
    /// Spawn the Phoenix release and store the child handle. Returns an error
    /// without touching the stored child if the spawn itself fails.
    fn spawn_release(&self) -> Result<(), String> {
        let stdout_log = open_log(&self.logs_dir, "release.stdout.log")?;
        let stderr_log = open_log(&self.logs_dir, "release.stderr.log")?;

        let child = Command::new(&self.release_bin)
            .arg("start")
            .env("PHX_SERVER", "true")
            .env("PORT", self.port.to_string())
            .env("DATABASE_PATH", &self.database_path)
            .env("BUSTER_CLAW_WORKSPACE_ROOT", &self.workspace_root)
            .env("SECRET_KEY_BASE", &self.secret_key_base)
            .env("BUSTER_CLAW_API_TOKEN", &self.api_token)
            .env("BUSTER_CLAW_MCP_API_TOKEN", &self.mcp_token)
            .env("RELEASE_DISTRIBUTION", "none")
            .stdout(Stdio::from(stdout_log))
            .stderr(Stdio::from(stderr_log))
            .spawn()
            .map_err(|e| format!("failed to spawn Phoenix release: {e}"))?;

        *self
            .release_child
            .lock()
            .map_err(|e| format!("release child mutex poisoned: {e}"))? = Some(child);
        Ok(())
    }

    /// Health-poll the release and point the webview at it (or error.html). Run
    /// on the provided tokio runtime so it can reuse the current-thread reactor.
    fn await_health_and_navigate(&self, runtime: &tokio::runtime::Runtime) {
        let health_url = format!("{}/_health", self.phoenix_url);
        let handle = self.handle.clone();
        let phoenix_url = self.phoenix_url.clone();

        runtime.block_on(async move {
            let healthy = wait_for_health(&health_url).await;
            let Some(window) = handle.get_webview_window("main") else {
                eprintln!("[buster-claw] main window missing during startup transition");
                return;
            };

            let target = if healthy {
                phoenix_url.clone()
            } else {
                "error.html".to_string()
            };

            if let Err(e) = window.eval(&format!(
                "window.location.replace({})",
                js_string_literal(&target)
            )) {
                eprintln!("[buster-claw] failed to navigate webview: {e}");
            }

            if let Err(e) = window.show() {
                eprintln!("[buster-claw] failed to show main window: {e}");
            }
            let _ = window.set_focus();
        });
    }

    /// Point the webview at error.html (used when we give up respawning).
    fn navigate_to_error(&self) {
        let Some(window) = self.handle.get_webview_window("main") else {
            return;
        };
        if let Err(e) = window.eval(&format!(
            "window.location.replace({})",
            js_string_literal("error.html")
        )) {
            eprintln!("[buster-claw] failed to navigate webview to error.html: {e}");
        }
    }
}

/// Background watchdog for the Phoenix release child (release builds only).
///
/// Waits on the spawned BEAM process; if it exits while the app is *not* shutting
/// down, respawns it with exponential backoff. A consecutive-restart guard
/// (`RESPAWN_MAX_RESTARTS` within `RESPAWN_RESTART_WINDOW`) trips the breaker:
/// the monitor navigates to error.html and stops trying so a doomed release
/// doesn't pin the CPU.
fn run_release_monitor(launcher: ReleaseLauncher) {
    // Dedicated current-thread runtime for the health polls this monitor drives.
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("[buster-claw] release monitor failed to build runtime: {e}");
            return;
        }
    };

    let mut backoff = RESPAWN_BACKOFF_BASE;
    let mut restart_count: u32 = 0;
    let mut window_start = Instant::now();

    loop {
        // Take ownership of the current child handle so we can wait on it without
        // holding the mutex (shutdown and respawn both need the lock).
        let mut child = {
            let Ok(mut guard) = launcher.release_child.lock() else {
                return;
            };
            match guard.take() {
                Some(c) => c,
                None => {
                    // No child to watch (already shut down, or never spawned).
                    if launcher.shutting_down.load(Ordering::SeqCst) {
                        return;
                    }
                    // Nothing tracked yet; brief pause then re-check.
                    drop(guard);
                    std::thread::sleep(Duration::from_millis(250));
                    continue;
                }
            }
        };

        // Poll for child exit while we still own it. We don't hold the mutex,
        // so the Exit handler can't reap it; that's fine — once we detect an
        // intentional shutdown we drop our handle and let shutdown_release run.
        loop {
            if launcher.shutting_down.load(Ordering::SeqCst) {
                // Intentional quit: hand the child back so shutdown_release can
                // SIGTERM it, then exit the monitor.
                if let Ok(mut guard) = launcher.release_child.lock() {
                    if guard.is_none() {
                        *guard = Some(child);
                    }
                }
                return;
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    eprintln!("[buster-claw] Phoenix release exited unexpectedly: {status}");
                    break;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(500)),
                Err(e) => {
                    eprintln!("[buster-claw] error waiting on release child: {e}");
                    break;
                }
            }
        }

        // Re-check the shutdown flag before respawning (it may have been set
        // while we were detecting the exit).
        if launcher.shutting_down.load(Ordering::SeqCst) {
            return;
        }

        // Consecutive-restart guard: reset the counter if the last failure was
        // long enough ago, otherwise trip the breaker.
        if window_start.elapsed() > RESPAWN_RESTART_WINDOW {
            restart_count = 0;
            window_start = Instant::now();
            backoff = RESPAWN_BACKOFF_BASE;
        }
        restart_count += 1;
        if restart_count > RESPAWN_MAX_RESTARTS {
            eprintln!(
                "[buster-claw] Phoenix release crash-looped ({} restarts in {:?}); giving up",
                restart_count - 1,
                RESPAWN_RESTART_WINDOW
            );
            launcher.navigate_to_error();
            return;
        }

        eprintln!(
            "[buster-claw] respawning Phoenix release in {:?} (attempt {restart_count}/{RESPAWN_MAX_RESTARTS})",
            backoff
        );
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(RESPAWN_BACKOFF_MAX);

        if launcher.shutting_down.load(Ordering::SeqCst) {
            return;
        }

        match launcher.spawn_release() {
            Ok(()) => launcher.await_health_and_navigate(&runtime),
            Err(e) => {
                eprintln!("[buster-claw] failed to respawn Phoenix release: {e}");
                // Loop again; backoff already advanced and the guard will trip
                // if this keeps failing.
            }
        }
    }
}

/// Build the application menu: the standard macOS menu with the Window →
/// "Close Window" item (Cmd-W) removed, so the JS-side tab-close handler can
/// fully own Cmd-W instead of the OS closing the whole window out from under it.
///
/// Tauri's `Menu::default` binds Cmd-W to a native `close_window` predefined
/// item, and that accelerator fires regardless of the webview's `keydown`
/// capture handler — so with a single tab open Cmd-W would close the entire
/// window before JS ever saw it. We replicate the default macOS menu verbatim
/// minus that one item; everything else (Quit/Cmd-Q, copy/paste, minimize,
/// fullscreen, etc.) stays intact so the app still feels native. The red
/// traffic-light X and Cmd-Q are untouched and still close/quit normally.
#[cfg(target_os = "macos")]
fn build_app_menu(handle: &tauri::AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    use tauri::menu::{AboutMetadataBuilder, Menu, PredefinedMenuItem, Submenu};

    let pkg_info = handle.package_info();
    let config = handle.config();
    let about_metadata = AboutMetadataBuilder::new()
        .name(Some(pkg_info.name.clone()))
        .version(Some(pkg_info.version.to_string()))
        .copyright(config.bundle.copyright.clone())
        .authors(config.bundle.publisher.clone().map(|p| vec![p]))
        .build();

    let app_menu = Submenu::with_items(
        handle,
        pkg_info.name.clone(),
        true,
        &[
            &PredefinedMenuItem::about(handle, None, Some(about_metadata))?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::services(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::hide(handle, None)?,
            &PredefinedMenuItem::hide_others(handle, None)?,
            &PredefinedMenuItem::show_all(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::quit(handle, None)?,
        ],
    )?;

    let edit_menu = Submenu::with_items(
        handle,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(handle, None)?,
            &PredefinedMenuItem::redo(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::cut(handle, None)?,
            &PredefinedMenuItem::copy(handle, None)?,
            &PredefinedMenuItem::paste(handle, None)?,
            &PredefinedMenuItem::select_all(handle, None)?,
        ],
    )?;

    let view_menu = Submenu::with_items(
        handle,
        "View",
        true,
        &[&PredefinedMenuItem::fullscreen(handle, None)?],
    )?;

    // Standard Window menu MINUS `PredefinedMenuItem::close_window` (Cmd-W).
    // Dropping that item is the whole point of this custom menu — see the doc
    // comment above. The trailing separator that preceded it in the default
    // menu is dropped with it.
    let window_menu = Submenu::with_items(
        handle,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(handle, None)?,
            &PredefinedMenuItem::maximize(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::fullscreen(handle, None)?,
        ],
    )?;

    Menu::with_items(handle, &[&app_menu, &edit_menu, &view_menu, &window_menu])
}

/// Non-macOS targets keep Tauri's stock menu unchanged — the Cmd-W concern is
/// macOS-specific and this app ships only on macOS.
#[cfg(not(target_os = "macos"))]
fn build_app_menu(handle: &tauri::AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    tauri::menu::Menu::default(handle)
}

fn main() {
    let release_child: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));
    let release_child_for_setup = Arc::clone(&release_child);
    let release_child_for_run = Arc::clone(&release_child);

    // Set in the Exit handler so the release monitor doesn't fight an
    // intentional quit by respawning a child we just SIGTERMed.
    let shutting_down = Arc::new(AtomicBool::new(false));
    let shutting_down_for_setup = Arc::clone(&shutting_down);
    let shutting_down_for_run = Arc::clone(&shutting_down);

    let app = tauri::Builder::default()
        .menu(build_app_menu)
        .manage(terminal::TerminalState::default())
        .manage(browser::BrowserState::default())
        .invoke_handler(tauri::generate_handler![
            terminal::terminal_open,
            terminal::terminal_attach,
            terminal::terminal_input,
            terminal::terminal_resize,
            terminal::terminal_busy,
            terminal::terminal_close,
            browser::browser_open,
            browser::browser_set_bounds,
            browser::browser_navigate,
            browser::browser_back,
            browser::browser_forward,
            browser::browser_reload,
            browser::browser_new_tab,
            browser::browser_switch_tab,
            browser::browser_close_tab,
            browser::browser_hide,
            browser::browser_close,
            browser::browser_screenshot,
            voice::speak,
            voice::stop_speaking
        ])
        .setup(move |app| {
            let handle = app.handle().clone();

            if cfg!(debug_assertions) {
                // Dev mode: expect `mix phx.server` running externally on :4000.
                // Skipping the bundled-release spawn lets LiveView hot-reload Elixir
                // edits straight into the Tauri webview. No release child, no
                // respawn monitor, and no no-sleep assertion in dev.
                let phoenix_url = "http://127.0.0.1:4000".to_string();
                let health_url = format!("{phoenix_url}/_health");

                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|e| format!("failed to build tokio runtime: {e}"))?;

                std::thread::spawn(move || {
                    runtime.block_on(async move {
                        let healthy = wait_for_health(&health_url).await;
                        let Some(window) = handle.get_webview_window("main") else {
                            eprintln!(
                                "[buster-claw] main window missing during startup transition"
                            );
                            return;
                        };

                        let target = if healthy {
                            phoenix_url.clone()
                        } else {
                            "error.html".to_string()
                        };

                        if let Err(e) = window.eval(&format!(
                            "window.location.replace({})",
                            js_string_literal(&target)
                        )) {
                            eprintln!("[buster-claw] failed to navigate webview: {e}");
                        }

                        if let Err(e) = window.show() {
                            eprintln!("[buster-claw] failed to show main window: {e}");
                        }
                        let _ = window.set_focus();
                    });
                });

                return Ok(());
            }

            // --- Release mode: bundled BEAM + respawn monitor ---
            let data_dir = resolve_data_dir()?;
            ensure_data_dirs(&data_dir)?;
            // Master key + loopback API tokens come from the Keychain (migrated
            // once from the legacy plaintext files, or adopted from a user-dropped
            // RESTORE_SECRET_KEY recovery file). The 43-char tokens match the
            // entropy of the Elixir-side generator they replace.
            let secret_key_base = ensure_secret(
                &data_dir,
                "secret_key_base",
                &["RESTORE_SECRET_KEY", "secret_key_base"],
                64,
            )?;
            let api_token = ensure_secret(&data_dir, "api_token", &["api_token"], 43)?;
            let mcp_token = ensure_secret(&data_dir, "mcp_token", &["mcp_token"], 43)?;
            let workspace_root = workspace::resolve_workspace_root(&data_dir)?;
            workspace::ensure_workspace_dirs(&workspace_root)?;
            let database_path = data_dir.join("buster_claw.db");
            let logs_dir = data_dir.join("logs");

            let port = portpicker::pick_unused_port()
                .ok_or_else(|| "no free TCP port available".to_string())?;

            let release_bin = resolve_release_binary(app)?;

            // No-sleep + relaunch are shift-scoped and owned by the Elixir
            // `BusterClaw.Orchestration.Uptime` GenServer (caffeinate + launchd),
            // engaged only while a shift is active — not by this shell.

            let launcher = ReleaseLauncher {
                handle: handle.clone(),
                release_child: Arc::clone(&release_child_for_setup),
                shutting_down: Arc::clone(&shutting_down_for_setup),
                release_bin,
                logs_dir,
                database_path,
                workspace_root,
                secret_key_base,
                api_token,
                mcp_token,
                port,
                phoenix_url: format!("http://127.0.0.1:{port}"),
            };

            // Make the in-app terminal's `./buster-claw` reach THIS release. The
            // CLI reads BUSTER_CLAW_URL (this app's private port, not the CLI's
            // :4000 default) and BUSTER_CLAW_API_TOKEN (the Keychain token, which
            // the CLI cannot read on its own) from the environment; the terminal
            // PTY (terminal.rs) forwards them from this process's env.
            std::env::set_var("BUSTER_CLAW_URL", &launcher.phoenix_url);
            std::env::set_var("BUSTER_CLAW_API_TOKEN", &launcher.api_token);

            // Initial boot: spawn the release, then transition the webview once
            // healthy. Done on a background thread so setup() returns promptly.
            launcher.spawn_release()?;
            std::thread::spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        eprintln!("[buster-claw] failed to build tokio runtime: {e}");
                        return;
                    }
                };
                launcher.await_health_and_navigate(&runtime);
                // Hand off to the watchdog: from here it owns the child handle,
                // respawning on unexpected exit until shutdown or crash-loop.
                run_release_monitor(launcher);
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Buster Claw desktop shell");

    app.run(move |handle, event| {
        if matches!(event, RunEvent::Exit) {
            // Signal the respawn monitor to stand down before we reap the child,
            // so it doesn't race us by spawning a replacement.
            shutting_down_for_run.store(true, Ordering::SeqCst);
            terminal::shutdown_all(handle);
            shutdown_release(&release_child_for_run);
        }
    });
}

pub(crate) fn resolve_data_dir() -> Result<PathBuf, String> {
    let base = dirs::data_dir().ok_or_else(|| "could not resolve user data dir".to_string())?;
    Ok(base.join(APP_DATA_DIR_NAME))
}

fn ensure_data_dirs(data_dir: &Path) -> Result<(), String> {
    // The library/sources/analysis/memory tree now lives under the user-chosen
    // workspace root (see `workspace::ensure_workspace_dirs`); the data dir only
    // holds app-internal state such as logs, the DB, and the secret key.
    fs::create_dir_all(data_dir.join("logs"))
        .map_err(|e| format!("failed to create logs dir: {e}"))?;
    Ok(())
}

// --- Secret material: macOS Keychain, with a one-time migration from the
// legacy plaintext files older shells wrote into the data dir ---

fn keychain_entry(account: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYCHAIN_SERVICE, account)
        .map_err(|e| format!("keychain entry error for {account}: {e}"))
}

fn keychain_get(account: &str) -> Result<Option<String>, String> {
    match keychain_entry(account)?.get_password() {
        Ok(v) => Ok(Some(v)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(format!("keychain read error for {account}: {e}")),
    }
}

fn keychain_set(account: &str, value: &str) -> Result<(), String> {
    keychain_entry(account)?
        .set_password(value)
        .map_err(|e| format!("keychain write error for {account}: {e}"))
}

fn random_alphanumeric(len: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(len)
        .map(char::from)
        .collect()
}

/// Resolve a secret, preferring the Keychain. On a cold machine the candidate
/// files in `data_dir` are tried in order — a user-dropped recovery file, then a
/// legacy plaintext file from an older shell. The first non-empty one is adopted
/// into the Keychain and then deleted, so secret material never lingers on disk.
/// If nothing is found, a fresh secret is generated and stored.
fn ensure_secret(
    data_dir: &Path,
    account: &str,
    migrate_files: &[&str],
    len: usize,
) -> Result<String, String> {
    if let Some(existing) = keychain_get(account)? {
        let trimmed = existing.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }

    for file in migrate_files {
        let path = data_dir.join(file);
        if !path.exists() {
            continue;
        }
        let mut buf = String::new();
        File::open(&path)
            .and_then(|mut f| f.read_to_string(&mut buf))
            .map_err(|e| format!("failed to read {file}: {e}"))?;
        let value = buf.trim().to_string();
        if value.is_empty() {
            continue;
        }
        keychain_set(account, &value)?;
        // Secret now lives in the Keychain; drop the on-disk copy (best-effort).
        let _ = fs::remove_file(&path);
        return Ok(value);
    }

    let generated = random_alphanumeric(len);
    keychain_set(account, &generated)?;
    Ok(generated)
}

fn resolve_release_binary(app: &tauri::App) -> Result<PathBuf, String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("failed to resolve resource dir: {e}"))?;
    let bin = resource_dir.join("release/bin/buster_claw");
    if !bin.exists() {
        return Err(format!(
            "release binary not found at {} \u{2014} run scripts/build_desktop.sh",
            bin.display()
        ));
    }
    Ok(bin)
}

fn open_log(logs_dir: &Path, file: &str) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(logs_dir.join(file))
        .map_err(|e| format!("failed to open log {file}: {e}"))
}

async fn wait_for_health(url: &str) -> bool {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
    {
        Ok(c) => c,
        Err(_) => return false,
    };

    let deadline = Instant::now() + HEALTH_TIMEOUT;
    while Instant::now() < deadline {
        if let Ok(resp) = client.get(url).send().await {
            if resp.status().is_success() {
                return true;
            }
        }
        tokio::time::sleep(HEALTH_POLL_INTERVAL).await;
    }
    false
}

fn shutdown_release(child: &Arc<Mutex<Option<Child>>>) {
    let Ok(mut guard) = child.lock() else { return };
    let Some(mut process) = guard.take() else {
        return;
    };

    #[cfg(unix)]
    {
        let pid = process.id().to_string();
        let _ = Command::new("kill").arg("-TERM").arg(&pid).status();
    }

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match process.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() >= deadline => break,
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(_) => break,
        }
    }
    let _ = process.kill();
    let _ = process.wait();
}

fn js_string_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
