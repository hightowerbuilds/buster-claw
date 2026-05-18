#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rand::distributions::Alphanumeric;
use rand::Rng;
use tauri::{Manager, RunEvent};

const APP_DATA_DIR_NAME: &str = "BusterClaw";
const HEALTH_TIMEOUT: Duration = Duration::from_secs(30);
const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(250);

fn main() {
    let release_child: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));
    let release_child_for_setup = Arc::clone(&release_child);
    let release_child_for_run = Arc::clone(&release_child);

    let app = tauri::Builder::default()
        .setup(move |app| {
            let handle = app.handle().clone();

            let phoenix_url = if cfg!(debug_assertions) {
                // Dev mode: expect `mix phx.server` running externally on :4000.
                // Skipping the bundled-release spawn lets LiveView hot-reload Elixir
                // edits straight into the Tauri webview.
                "http://127.0.0.1:4000".to_string()
            } else {
                let data_dir = resolve_data_dir()?;
                ensure_data_dirs(&data_dir)?;
                let secret_key_base = ensure_secret_key_base(&data_dir)?;
                let library_root = data_dir.join("Library");
                let database_path = data_dir.join("buster_claw.db");
                let logs_dir = data_dir.join("logs");

                let port = portpicker::pick_unused_port()
                    .ok_or_else(|| "no free TCP port available".to_string())?;

                let release_bin = resolve_release_binary(app)?;
                let stdout_log = open_log(&logs_dir, "release.stdout.log")?;
                let stderr_log = open_log(&logs_dir, "release.stderr.log")?;

                let child = Command::new(&release_bin)
                    .arg("start")
                    .env("PHX_SERVER", "true")
                    .env("PORT", port.to_string())
                    .env("DATABASE_PATH", &database_path)
                    .env("BUSTER_CLAW_LIBRARY_ROOT", &library_root)
                    .env("SECRET_KEY_BASE", &secret_key_base)
                    .env("RELEASE_DISTRIBUTION", "none")
                    .stdout(Stdio::from(stdout_log))
                    .stderr(Stdio::from(stderr_log))
                    .spawn()
                    .map_err(|e| format!("failed to spawn Phoenix release: {e}"))?;

                *release_child_for_setup
                    .lock()
                    .map_err(|e| format!("release child mutex poisoned: {e}"))? = Some(child);

                format!("http://127.0.0.1:{port}")
            };

            let health_url = format!("{phoenix_url}/_health");

            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| format!("failed to build tokio runtime: {e}"))?;

            std::thread::spawn(move || {
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
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Buster Claw desktop shell");

    app.run(move |_handle, event| {
        if matches!(event, RunEvent::Exit) {
            shutdown_release(&release_child_for_run);
        }
    });
}

fn resolve_data_dir() -> Result<PathBuf, String> {
    let base = dirs::data_dir().ok_or_else(|| "could not resolve user data dir".to_string())?;
    Ok(base.join(APP_DATA_DIR_NAME))
}

fn ensure_data_dirs(data_dir: &Path) -> Result<(), String> {
    for sub in ["Library/raw", "Library/reports", "logs"] {
        fs::create_dir_all(data_dir.join(sub))
            .map_err(|e| format!("failed to create {sub}: {e}"))?;
    }
    Ok(())
}

fn ensure_secret_key_base(data_dir: &Path) -> Result<String, String> {
    let key_path = data_dir.join("secret_key_base");
    if key_path.exists() {
        let mut buf = String::new();
        File::open(&key_path)
            .and_then(|mut f| f.read_to_string(&mut buf))
            .map_err(|e| format!("failed to read secret_key_base: {e}"))?;
        return Ok(buf.trim().to_string());
    }
    let generated: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(64)
        .map(char::from)
        .collect();
    fs::write(&key_path, &generated)
        .map_err(|e| format!("failed to write secret_key_base: {e}"))?;
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
