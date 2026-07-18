//! Workspace folder resolution + persistence.
//!
//! The chosen workspace root is persisted as a plain-text file (`workspace_root`)
//! in the Tauri data dir — the same convention `secret_key_base` uses — so that
//! `main.rs` can read it at boot, before Phoenix is spawned, and pass it through
//! as `BUSTER_CLAW_WORKSPACE_ROOT`. The workspace contains `library/` (the doc
//! store) plus `sources/`, `analysis/`, and `memory/` siblings.
//!
//! Browsing/selecting a workspace is now an in-app, server-side file tree
//! (Phoenix `BusterClaw.FileManager` + `WorkspaceLive`), which also writes this
//! same file directly. This module therefore only handles boot-time resolution.

use std::fs;
use std::path::{Path, PathBuf};

const WORKSPACE_FILE: &str = "workspace_root";
const SUBDIRS: [&str; 5] = ["library/raw", "library/reports", "sources", "analysis", "memory"];

/// Default workspace location for a fresh install: `~/Desktop/BusterClawCLI`.
pub fn default_workspace_root() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "could not resolve home dir".to_string())?;
    Ok(home.join("Desktop").join("BusterClawCLI"))
}

fn config_path(data_dir: &Path) -> PathBuf {
    data_dir.join(WORKSPACE_FILE)
}

/// Read the persisted workspace root, falling back to (and persisting) the
/// default on first run. Always returns an absolute path.
pub fn resolve_workspace_root(data_dir: &Path) -> Result<PathBuf, String> {
    let path = config_path(data_dir);
    if let Ok(contents) = fs::read_to_string(&path) {
        let trimmed = contents.trim();
        if !trimmed.is_empty() {
            return Ok(PathBuf::from(trimmed));
        }
    }

    let default = default_workspace_root()?;
    if let Err(e) = fs::write(&path, default.to_string_lossy().as_bytes()) {
        eprintln!(
            "[buster-claw] failed to persist workspace config {}: {e}",
            path.display()
        );
    }
    Ok(default)
}

/// Create the workspace layout: `library/{raw,reports}` plus the
/// `sources/`, `analysis/`, and `memory/` siblings.
pub fn ensure_workspace_dirs(workspace_root: &Path) -> Result<(), String> {
    for sub in SUBDIRS {
        fs::create_dir_all(workspace_root.join(sub))
            .map_err(|e| format!("failed to create {sub}: {e}"))?;
    }
    Ok(())
}
