//! Push-side reporting: chrome-JS pings (`window.__on*` hooks via eval) and
//! the HTTP reports to Phoenix (`/browser/history`, `/browser/download`) that
//! put navigation and downloads on the server-side audit trail.

use std::path::Path;

use tauri::{AppHandle, Manager, State, Url};

use super::active_sid;
use super::js::js_str;
use super::labels::chrome_label;
use super::state::BrowserState;

// Report a finished download to Phoenix (`POST /browser/download`) so it lands
// on the Sentinel audit feed — a download pulls untrusted bytes onto disk, the
// one browser ingress the server-side fetch pipeline never sees.
pub(super) fn report_download(
    app: &AppHandle,
    chrome_label: &str,
    url: &str,
    file: &Path,
    success: bool,
) {
    let Some(origin) = phoenix_origin(app, chrome_label) else {
        return;
    };
    let endpoint = format!("{origin}/browser/download");
    let query = vec![
        ("url".to_string(), url.to_string()),
        ("file".to_string(), file.display().to_string()),
        ("success".to_string(), success.to_string()),
    ];
    tauri::async_runtime::spawn(async move {
        if let Err(e) = reqwest::Client::new()
            .post(&endpoint)
            .query(&query)
            .send()
            .await
        {
            eprintln!("[buster-claw] download report to {endpoint} failed: {e}");
        }
    });
}

// Flash the co-presence badge in the surface's chrome so the user always sees
// when the agent has its hands on their live tab (trust is the product). Best
// effort — a closed browser (no chrome) is a silent no-op. Each co-presence
// command pings this at the top; the chrome shows the badge and auto-fades.
pub(super) fn ping_agent_activity(
    app: &AppHandle,
    state: &State<BrowserState>,
    surface_id: Option<String>,
    action: &str,
) {
    let sid = active_sid(state, surface_id);
    if let Some(chrome) = app.get_webview(&chrome_label(&sid)) {
        let _ = chrome.eval(format!(
            "window.__agentActivity && window.__agentActivity({})",
            js_str(action)
        ));
    }
}

// Tell a surface's chrome that a tab finished loading, passing the page's real
// title so the tab label can show it (the chrome falls back to the hostname when
// the title is empty). The favicon is derived host-side in the chrome JS.
//
// macOS reads WKWebView's `title` directly (same in-process objc bridge the
// screenshot path uses); other platforms pass an empty title and the chrome
// keeps the hostname label.
#[cfg(target_os = "macos")]
pub(super) fn notify_navigated(
    app: &AppHandle,
    chrome_label: &str,
    tab_id: &str,
    url: &str,
    content: &tauri::Webview,
) {
    let app = app.clone();
    let chrome_label = chrome_label.to_string();
    let tab_id = tab_id.to_string();
    let url = url.to_string();
    // `with_webview` runs on the main thread, where reading the WKWebView title
    // and dispatching the chrome eval are both safe.
    let _ = content.with_webview(move |pw| {
        use objc::runtime::Object;
        use objc::{msg_send, sel, sel_impl};
        let title = unsafe {
            let wk = pw.inner() as *mut Object;
            if wk.is_null() {
                String::new()
            } else {
                let ns: *mut Object = msg_send![wk, title];
                super::ffi::nsstring_to_string(ns).unwrap_or_default()
            }
        };
        emit_navigated(&app, &chrome_label, &tab_id, &url, &title);
    });
}

#[cfg(not(target_os = "macos"))]
pub(super) fn notify_navigated(
    app: &AppHandle,
    chrome_label: &str,
    tab_id: &str,
    url: &str,
    _content: &tauri::Webview,
) {
    emit_navigated(app, chrome_label, tab_id, url, "");
}

pub(super) fn emit_navigated(
    app: &AppHandle,
    chrome_label: &str,
    tab_id: &str,
    url: &str,
    title: &str,
) {
    if let Some(chrome) = app.get_webview(chrome_label) {
        let _ = chrome.eval(format!(
            "window.__onContentNavigated && window.__onContentNavigated({}, {}, {})",
            js_str(tab_id),
            js_str(url),
            js_str(title)
        ));
    }
    record_history(app, chrome_label, url, title);
}

/// Record a finished page load into Phoenix browser history
/// (`POST /browser/history`). Runs here — not in the chrome JS — so *every*
/// tab's loads are recorded, not just the active one's, and a chrome hiccup
/// can't silently drop history. The Phoenix origin is read off the chrome
/// webview (which always lives on it); the browser homepage is skipped.
// The Phoenix origin, read off a chrome webview (which always lives on it).
fn phoenix_origin(app: &AppHandle, chrome_label: &str) -> Option<String> {
    app.get_webview(chrome_label)
        .and_then(|chrome| chrome.url().ok())
        .map(|u| u.origin().ascii_serialization())
}

pub(super) fn record_history(app: &AppHandle, chrome_label: &str, url: &str, title: &str) {
    let Ok(parsed) = url.parse::<Url>() else {
        return;
    };
    if !matches!(parsed.scheme(), "http" | "https") {
        return;
    }
    let Some(origin) = phoenix_origin(app, chrome_label) else {
        return;
    };
    if parsed.origin().ascii_serialization() == origin && parsed.path() == "/browser/home" {
        return;
    }

    let endpoint = format!("{origin}/browser/history");
    let mut query = vec![("url".to_string(), url.to_string())];
    let label = title.trim();
    if !label.is_empty() {
        query.push(("label".to_string(), label.to_string()));
    }
    tauri::async_runtime::spawn(async move {
        if let Err(e) = reqwest::Client::new()
            .post(&endpoint)
            .query(&query)
            .send()
            .await
        {
            eprintln!("[buster-claw] history report to {endpoint} failed: {e}");
        }
    });
}
