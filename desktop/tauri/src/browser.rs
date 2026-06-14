//! Embedded browser with a native tab system.
//!
//! - **chrome** (`browser-chrome`): a strip on top loading our own toolbar + tab
//!   bar page, served by Phoenix so it can call the `browser_*` Tauri commands.
//! - **content** (`browser-content-<id>`): one webview per open tab, loading the
//!   external site. Each is in no capability, so loaded pages get no Tauri access.
//!   Exactly one content webview is shown at a time (the active tab); the rest are
//!   hidden but kept alive so switching is instant and state is preserved.
//!
//! The chrome JS owns the tab-strip UI and tab lifecycle; Rust owns the webviews
//! and the active-tab pointer (`BrowserState`) so navigate/back/forward/reload and
//! show-on-return act on the right tab without the chrome re-passing it each time.

use std::sync::Mutex;
use tauri::webview::WebviewBuilder;
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Url, WebviewUrl};

const CHROME_LABEL: &str = "browser-chrome";
const CONTENT_PREFIX: &str = "browser-content-";
const FIRST_TAB: &str = "1";
const CHROME_HEIGHT: f64 = 80.0; // tab strip (~34) + toolbar (46)

/// The currently-active content tab id (the visible one). Managed by Tauri so it
/// survives across commands; the chrome JS keeps it in sync via the tab commands.
#[derive(Default)]
pub struct BrowserState {
    active: Mutex<Option<String>>,
}

impl BrowserState {
    fn set(&self, id: &str) {
        *self.active.lock().unwrap() = Some(id.to_string());
    }
    fn get(&self) -> Option<String> {
        self.active.lock().unwrap().clone()
    }
    fn clear(&self) {
        *self.active.lock().unwrap() = None;
    }
}

// Injected into each content webview before page scripts: keep popups and
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

fn content_label(id: &str) -> String {
    format!("{CONTENT_PREFIX}{id}")
}

fn content_labels(app: &AppHandle) -> Vec<String> {
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(CONTENT_PREFIX))
        .cloned()
        .collect()
}

/// Open the browser: ensure the chrome strip, then show the active content tab
/// (creating the first tab on a cold open, or re-showing the saved active tab on
/// return to `/browse` after `browser_hide`).
#[tauri::command]
pub fn browser_open(
    app: AppHandle,
    state: State<BrowserState>,
    chrome_url: String,
    content_url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let chrome_h = CHROME_HEIGHT.min(height);
    let content_h = (height - chrome_h).max(0.0);
    let cy = y + chrome_h;

    ensure_chrome(&app, &chrome_url, x, y, width, chrome_h)?;

    // Pick the tab to show: the saved active one if it still exists, else any
    // existing content tab, else create the first tab.
    let labels = content_labels(&app);
    let active = state
        .get()
        .filter(|id| labels.contains(&content_label(id)));

    let show_id = match active {
        Some(id) => id,
        None => match labels.first() {
            Some(label) => label.trim_start_matches(CONTENT_PREFIX).to_string(),
            None => {
                create_content(&app, FIRST_TAB, &content_url, x, cy, width, content_h)?;
                FIRST_TAB.to_string()
            }
        },
    };

    state.set(&show_id);
    show_only(&app, &show_id, x, cy, width, content_h);
    Ok(())
}

/// Reposition/resize the chrome + every content webview to track the surface box.
/// Does not change visibility (the active tab stays shown, hidden tabs stay hidden).
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
    let cy = y + chrome_h;

    place(&app, CHROME_LABEL, x, y, width, chrome_h);
    show(&app, CHROME_LABEL);
    for label in content_labels(&app) {
        place(&app, &label, x, cy, width, content_h);
    }
    Ok(())
}

/// Open a new tab: create its content webview and make it the active (visible) one.
/// Bounds are copied from an existing content webview so it appears correctly placed.
#[tauri::command]
pub fn browser_new_tab(
    app: AppHandle,
    state: State<BrowserState>,
    tab_id: String,
    url: String,
) -> Result<(), String> {
    let (x, y, w, h) = sample_content_bounds(&app).ok_or("no content bounds yet")?;
    create_content(&app, &tab_id, &url, x, y, w, h)?;
    state.set(&tab_id);
    show_only(&app, &tab_id, x, y, w, h);
    Ok(())
}

/// Switch the visible tab to `tab_id`.
#[tauri::command]
pub fn browser_switch_tab(
    app: AppHandle,
    state: State<BrowserState>,
    tab_id: String,
) -> Result<(), String> {
    let (x, y, w, h) = sample_content_bounds(&app).unwrap_or((0.0, 0.0, 0.0, 0.0));
    state.set(&tab_id);
    show_only(&app, &tab_id, x, y, w, h);
    Ok(())
}

/// Close one tab's content webview. The chrome then switches to a neighbour.
#[tauri::command]
pub fn browser_close_tab(app: AppHandle, tab_id: String) -> Result<(), String> {
    if let Some(webview) = app.get_webview(&content_label(&tab_id)) {
        webview.close().map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Navigate a tab's content webview (called from the chrome toolbar with the
/// chrome's active tab id). Falls back to the state's active tab, then any tab.
#[tauri::command]
pub fn browser_navigate(
    app: AppHandle,
    state: State<BrowserState>,
    tab_id: String,
    url: String,
) -> Result<(), String> {
    let Some(webview) = resolve_target(&app, &state, &tab_id) else {
        return Err(format!("no content webview for tab {tab_id}"));
    };
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;
    webview.navigate(parsed).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_back(
    app: AppHandle,
    state: State<BrowserState>,
    tab_id: String,
) -> Result<(), String> {
    tab_eval(&app, &state, &tab_id, "history.back()")
}

#[tauri::command]
pub fn browser_forward(
    app: AppHandle,
    state: State<BrowserState>,
    tab_id: String,
) -> Result<(), String> {
    tab_eval(&app, &state, &tab_id, "history.forward()")
}

#[tauri::command]
pub fn browser_reload(
    app: AppHandle,
    state: State<BrowserState>,
    tab_id: String,
) -> Result<(), String> {
    tab_eval(&app, &state, &tab_id, "location.reload()")
}

/// Hide the chrome + all content webviews without destroying them — used when
/// leaving `/browse` so every tab persists when the user returns.
#[tauri::command]
pub fn browser_hide(app: AppHandle) -> Result<(), String> {
    let mut labels = content_labels(&app);
    labels.push(CHROME_LABEL.to_string());
    for label in labels {
        if let Some(webview) = app.get_webview(&label) {
            webview.hide().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Tear the chrome + every tab down entirely.
#[tauri::command]
pub fn browser_close(app: AppHandle, state: State<BrowserState>) -> Result<(), String> {
    let mut labels = content_labels(&app);
    labels.push(CHROME_LABEL.to_string());
    for label in labels {
        if let Some(webview) = app.get_webview(&label) {
            webview.close().map_err(|e| e.to_string())?;
        }
    }
    state.clear();
    Ok(())
}

// --- internals ----------------------------------------------------------

// Show one content tab, hide every other; (re)position the shown one.
fn show_only(app: &AppHandle, id: &str, x: f64, y: f64, w: f64, h: f64) {
    let target = content_label(id);
    for label in content_labels(app) {
        if let Some(webview) = app.get_webview(&label) {
            if label == target {
                if w > 0.0 && h > 0.0 {
                    let _ = webview.set_position(LogicalPosition::new(x, y));
                    let _ = webview.set_size(LogicalSize::new(w, h));
                }
                let _ = webview.show();
            } else {
                let _ = webview.hide();
            }
        }
    }
}

// Bounds of any existing content webview (so a new/switched tab lands correctly).
fn sample_content_bounds(app: &AppHandle) -> Option<(f64, f64, f64, f64)> {
    let label = content_labels(app).into_iter().next()?;
    let webview = app.get_webview(&label)?;
    let pos = webview.position().ok()?;
    let size = webview.size().ok()?;
    let scale = app.get_window("main").and_then(|w| w.scale_factor().ok()).unwrap_or(1.0);
    Some((
        pos.x as f64 / scale,
        pos.y as f64 / scale,
        size.width as f64 / scale,
        size.height as f64 / scale,
    ))
}

fn ensure_chrome(
    app: &AppHandle,
    url: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    if app.get_webview(CHROME_LABEL).is_some() {
        place(app, CHROME_LABEL, x, y, width, height);
        show(app, CHROME_LABEL);
        return Ok(());
    }
    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let parsed: Url = url.parse().map_err(|e| format!("invalid url {url}: {e}"))?;
    window
        .add_child(
            WebviewBuilder::new(CHROME_LABEL, WebviewUrl::External(parsed)),
            LogicalPosition::new(x, y),
            LogicalSize::new(width, height),
        )
        .map_err(|e| format!("failed to create chrome: {e}"))?;
    Ok(())
}

// Create a content webview for `tab_id` with the navigation guard, popup guard,
// and per-tab navigation reporting back to the chrome.
fn create_content(
    app: &AppHandle,
    tab_id: &str,
    url: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let label = content_label(tab_id);
    if app.get_webview(&label).is_some() {
        return Ok(());
    }
    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let parsed: Url = url.parse().map_err(|e| format!("invalid url {url}: {e}"))?;

    let app_for_nav = app.clone();
    let id_for_nav = tab_id.to_string();
    let builder = WebviewBuilder::new(&label, WebviewUrl::External(parsed))
        .on_navigation(move |url| {
            // Lock to web navigation: block file://, tauri://, javascript:, data:.
            let allowed = matches!(url.scheme(), "http" | "https") || url.as_str() == "about:blank";
            if allowed {
                if let Some(chrome) = app_for_nav.get_webview(CHROME_LABEL) {
                    let _ = chrome.eval(&format!(
                        "window.__onContentNavigated && window.__onContentNavigated({}, {})",
                        js_str(&id_for_nav),
                        js_str(url.as_str())
                    ));
                }
            }
            allowed
        })
        .initialization_script(NO_POPUPS_JS);

    window
        .add_child(
            builder,
            LogicalPosition::new(x, y),
            LogicalSize::new(width, height),
        )
        .map_err(|e| format!("failed to create {label}: {e}"))?;
    Ok(())
}

// Move/resize without changing visibility.
fn place(app: &AppHandle, label: &str, x: f64, y: f64, width: f64, height: f64) {
    if let Some(webview) = app.get_webview(label) {
        let _ = webview.set_position(LogicalPosition::new(x, y));
        let _ = webview.set_size(LogicalSize::new(width, height));
    }
}

fn show(app: &AppHandle, label: &str) {
    if let Some(webview) = app.get_webview(label) {
        let _ = webview.show();
    }
}

// The content webview to act on: the requested tab, else the state's active
// tab, else any open tab. Keeps nav working even if the chrome/Rust active
// pointers briefly diverge.
fn resolve_target(
    app: &AppHandle,
    state: &State<BrowserState>,
    tab_id: &str,
) -> Option<tauri::Webview> {
    app.get_webview(&content_label(tab_id))
        .or_else(|| state.get().and_then(|id| app.get_webview(&content_label(&id))))
        .or_else(|| content_labels(app).into_iter().next().and_then(|l| app.get_webview(&l)))
}

fn tab_eval(
    app: &AppHandle,
    state: &State<BrowserState>,
    tab_id: &str,
    js: &str,
) -> Result<(), String> {
    if let Some(webview) = resolve_target(app, state, tab_id) {
        webview.eval(js).map_err(|e| e.to_string())?;
    }
    Ok(())
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
