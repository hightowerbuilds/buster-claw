//! Embedded browser: two stacked native child webviews hosted in the main window.
//!
//! - **chrome** (`browser-chrome`): a thin strip on top loading our own toolbar
//!   page (address bar + back/forward/reload), served by Phoenix so it can call
//!   the `browser_*` Tauri commands. It's granted only those commands.
//! - **content** (`browser-content`): the rest, loading the external site. It's in
//!   no capability, so loaded pages get no Tauri access.
//!
//! Both are real webviews (no `X-Frame-Options` limits) positioned together by the
//! JS hook over the `/browse` surface. Because the chrome is itself a webview, it
//! can never be covered by the content — fixing the HTML-overlay problem.

use tauri::webview::WebviewBuilder;
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, Url, WebviewUrl};

const CHROME_LABEL: &str = "browser-chrome";
const CONTENT_LABEL: &str = "browser-content";
const CHROME_HEIGHT: f64 = 46.0;

// Injected into the content webview before page scripts: keep popups and
// target=_blank links in-place instead of spawning uncontrolled OS windows.
const NO_POPUPS_JS: &str = r#"
(function () {
  try {
    window.open = function (url) { if (url) { window.location.href = url; } return null; };
    document.addEventListener("click", function (e) {
      var a = e.target && e.target.closest && e.target.closest("a[target]");
      if (a && a.target && a.target !== "_self" && a.href) {
        e.preventDefault();
        window.location.href = a.href;
      }
    }, true);
  } catch (_e) {}
})();
"#;

/// Open (or reposition + show) the two-webview browser over the given box.
/// `chrome_url` is our Phoenix-served toolbar; `content_url` is the site.
#[tauri::command]
pub fn browser_open(
    app: AppHandle,
    chrome_url: String,
    content_url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let chrome_h = CHROME_HEIGHT.min(height);
    let content_h = (height - chrome_h).max(0.0);

    ensure_webview(&app, CHROME_LABEL, &chrome_url, x, y, width, chrome_h)?;
    ensure_webview(&app, CONTENT_LABEL, &content_url, x, y + chrome_h, width, content_h)?;
    Ok(())
}

/// Reposition/resize both webviews to track the surface box.
#[tauri::command]
pub fn browser_set_bounds(
    app: AppHandle,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let chrome_h = CHROME_HEIGHT.min(height);
    let content_h = (height - chrome_h).max(0.0);

    place(&app, CHROME_LABEL, x, y, width, chrome_h);
    place(&app, CONTENT_LABEL, x, y + chrome_h, width, content_h);
    Ok(())
}

/// Navigate the content webview (called from the chrome toolbar).
#[tauri::command]
pub fn browser_navigate(app: AppHandle, url: String) -> Result<(), String> {
    let Some(webview) = app.get_webview(CONTENT_LABEL) else {
        return Ok(());
    };
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;
    webview.navigate(parsed).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_back(app: AppHandle) -> Result<(), String> {
    content_eval(app, "history.back()")
}

#[tauri::command]
pub fn browser_forward(app: AppHandle) -> Result<(), String> {
    content_eval(app, "history.forward()")
}

#[tauri::command]
pub fn browser_reload(app: AppHandle) -> Result<(), String> {
    content_eval(app, "location.reload()")
}

/// Hide both webviews without destroying them — used when leaving `/browse` so
/// the page persists when the user returns.
#[tauri::command]
pub fn browser_hide(app: AppHandle) -> Result<(), String> {
    for label in [CHROME_LABEL, CONTENT_LABEL] {
        if let Some(webview) = app.get_webview(label) {
            webview.hide().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Tear both webviews down entirely.
#[tauri::command]
pub fn browser_close(app: AppHandle) -> Result<(), String> {
    for label in [CHROME_LABEL, CONTENT_LABEL] {
        if let Some(webview) = app.get_webview(label) {
            webview.close().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

// Create the webview if absent, else reposition + show (preserving its page).
fn ensure_webview(
    app: &AppHandle,
    label: &str,
    url: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    if app.get_webview(label).is_some() {
        place(app, label, x, y, width, height);
        return Ok(());
    }

    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let parsed: Url = url.parse().map_err(|e| format!("invalid url {url}: {e}"))?;

    let mut builder = WebviewBuilder::new(label, WebviewUrl::External(parsed));

    // Lock the content webview down to web navigation only: block file://,
    // tauri://, javascript:, data:, etc. so a loaded page can't read local files
    // or escape into app/IPC schemes. (The chrome webview only ever loads our own
    // loopback toolbar, so it doesn't need this.)
    if label == CONTENT_LABEL {
        let app_for_nav = app.clone();
        builder = builder
            .on_navigation(move |url| {
                let allowed =
                    matches!(url.scheme(), "http" | "https") || url.as_str() == "about:blank";

                // Reflect the destination in the chrome address bar so it tracks
                // navigation driven by in-page clicks (folders, files, links).
                if allowed {
                    if let Some(chrome) = app_for_nav.get_webview(CHROME_LABEL) {
                        let _ = chrome.eval(&format!(
                            "window.__setAddress && window.__setAddress({})",
                            js_str(url.as_str())
                        ));
                    }
                }

                allowed
            })
            .initialization_script(NO_POPUPS_JS);
    }

    window
        .add_child(
            builder,
            LogicalPosition::new(x, y),
            LogicalSize::new(width, height),
        )
        .map_err(|e| format!("failed to create {label}: {e}"))?;
    Ok(())
}

// Best-effort move/resize/show; missing webview is a no-op.
fn place(app: &AppHandle, label: &str, x: f64, y: f64, width: f64, height: f64) {
    if let Some(webview) = app.get_webview(label) {
        let _ = webview.set_position(LogicalPosition::new(x, y));
        let _ = webview.set_size(LogicalSize::new(width, height));
        let _ = webview.show();
    }
}

fn content_eval(app: AppHandle, js: &str) -> Result<(), String> {
    let Some(webview) = app.get_webview(CONTENT_LABEL) else {
        return Ok(());
    };
    webview.eval(js).map_err(|e| e.to_string())
}

// Encode a string as a JS string literal for safe interpolation into eval'd JS.
fn js_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
