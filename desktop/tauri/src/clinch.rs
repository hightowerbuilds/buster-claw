//! The Clinch's management gate — Phase 2.
//!
//! These three commands are the reason the desktop shell is load-bearing in the
//! credential design rather than decorative.
//!
//! A credential typed into a LiveView form travels as a `phx-change` payload,
//! lands in the socket's assigns and appears in the rendered diff. Routing the
//! write through here means the value goes from a plain DOM input straight to
//! Rust and then to loopback — never through the LiveView channel, never into an
//! assign, never into a diff.
//!
//! And it means a tunneled browser cannot manage credentials, for two
//! independent reasons:
//!
//! 1. A plain browser has no `window.__TAURI__` — the runtime injects it into
//!    Tauri webviews; it is not something the loopback origin serves. That is
//!    the honest UX boundary, but it is an absence, and an absence is one
//!    refactor from being papered over.
//! 2. `/api/clinch` requires the **full** API token, which lives in the macOS
//!    Keychain and this process's environment. A forwarding-only SSH key gets no
//!    shell, so it reaches no Keychain, so it holds no token. That is the
//!    enforcement, and it holds regardless of the first.
//!
//! Nothing here ever returns a credential value. `clinch_reveal_recovery_key` is
//! the single deliberate exception in the whole design, and it reads the
//! Keychain directly rather than asking Elixir — which is the point: the master
//! key stops being a LiveView assign at all.

use serde::Deserialize;
use std::time::Duration;

/// Keychain service and account for the master key. Must match `main.rs`.
const KEYCHAIN_SERVICE: &str = "BusterClaw";
const RECOVERY_ACCOUNT: &str = "secret_key_base";

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Deserialize)]
struct ApiError {
    error: Option<String>,
}

/// Where Phoenix is, and the token that opens its trusted routes.
///
/// In a packaged build `main.rs` sets both from the Keychain before the webview
/// exists. In dev there is no shell-spawned release, so fall back to the known
/// dev port and the dev token from `config/dev.exs` — otherwise this whole path
/// would be untestable outside a packaged build, which is how the ACL bugs of
/// 07-17 and 07-21 survived as long as they did.
fn endpoint() -> Result<(String, String), String> {
    let url =
        std::env::var("BUSTER_CLAW_URL").unwrap_or_else(|_| "http://127.0.0.1:4000".to_string());

    let token = std::env::var("BUSTER_CLAW_API_TOKEN").unwrap_or_else(|_| {
        if cfg!(debug_assertions) {
            "dev-token-loopback-only".to_string()
        } else {
            String::new()
        }
    });

    if token.is_empty() {
        return Err("no API token available to this shell".to_string());
    }

    Ok((url, token))
}

async fn send(
    method: reqwest::Method,
    body: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let (url, token) = endpoint()?;

    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|e| format!("http client error: {e}"))?;

    let response = client
        .request(method, format!("{url}/api/clinch"))
        .bearer_auth(token)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("clinch request failed: {e}"))?;

    let status = response.status();
    let text = response.text().await.unwrap_or_default();

    if status.is_success() {
        return serde_json::from_str(&text).map_err(|e| format!("bad clinch response: {e}"));
    }

    // Surface the app's own error slug so the UI can say something specific.
    // Never include the request body in the message — it carries the value.
    let slug = serde_json::from_str::<ApiError>(&text)
        .ok()
        .and_then(|e| e.error)
        .unwrap_or_else(|| status.as_str().to_string());

    Err(slug)
}

/// Store or replace a credential. Returns the stored entry — kind, name, note —
/// and never the value.
#[tauri::command]
pub async fn clinch_put(
    kind: String,
    name: String,
    value: String,
    note: Option<String>,
) -> Result<serde_json::Value, String> {
    let body = serde_json::json!({
        "kind": kind,
        "name": name,
        "value": value,
        "note": note,
    });

    send(reqwest::Method::POST, body).await
}

/// Forget a credential.
#[tauri::command]
pub async fn clinch_delete(kind: String, name: String) -> Result<serde_json::Value, String> {
    let body = serde_json::json!({ "kind": kind, "name": name });

    send(reqwest::Method::DELETE, body).await
}

/// Read the master recovery key straight from the Keychain.
///
/// The one command in the Clinch that returns a secret, and it deliberately does
/// not go through Elixir. `settings_live` used to assign the key and render it,
/// which put the value that decrypts every other credential into a LiveView
/// payload — harmless while loopback meant "at the Mac", and exactly the wrong
/// shape once a tunnel exists. Now it never reaches the server at all.
#[tauri::command]
pub fn clinch_reveal_recovery_key() -> Result<String, String> {
    let entry = keyring::Entry::new(KEYCHAIN_SERVICE, RECOVERY_ACCOUNT)
        .map_err(|e| format!("keychain entry error: {e}"))?;

    match entry.get_password() {
        Ok(value) if !value.trim().is_empty() => Ok(value.trim().to_string()),
        Ok(_) => Err("no recovery key is stored on this machine".to_string()),
        Err(keyring::Error::NoEntry) => {
            Err("no recovery key is stored on this machine".to_string())
        }
        Err(e) => Err(format!("keychain read error: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test, not two. Environment variables are process-global and cargo runs
    // tests on parallel threads, so a pair of tests each mutating BUSTER_CLAW_URL
    // would race and fail intermittently — the kind of flake that gets a suite
    // ignored rather than fixed.
    #[test]
    fn endpoint_prefers_injected_values_and_falls_back_in_dev() {
        std::env::remove_var("BUSTER_CLAW_URL");
        std::env::remove_var("BUSTER_CLAW_API_TOKEN");

        // Dev fallback: `cargo test` is a debug build, so a token is available
        // and this path stays exercisable outside a packaged app.
        let (url, token) = endpoint().expect("a debug build should have a fallback token");
        assert_eq!(url, "http://127.0.0.1:4000");
        assert!(!token.is_empty());

        // Injected values win.
        std::env::set_var("BUSTER_CLAW_URL", "http://127.0.0.1:44115");
        std::env::set_var("BUSTER_CLAW_API_TOKEN", "injected-token");

        let (url, token) = endpoint().unwrap();
        assert_eq!(url, "http://127.0.0.1:44115");
        assert_eq!(token, "injected-token");

        std::env::remove_var("BUSTER_CLAW_URL");
        std::env::remove_var("BUSTER_CLAW_API_TOKEN");
    }
}
