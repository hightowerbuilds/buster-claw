//! Embedded browser with a native tab system, instanceable per **surface**.
//!
//! A *surface* is one on-screen browser instance, keyed by a short id
//! (`"main"` for the solo `/browse`, `"left"`/`"right"` for the two panes of a
//! browser+browser split). Each surface is fully independent — its own chrome,
//! its own content tabs, its own active-tab pointer.
//!
//! - **chrome** (`browser-chrome-<sid>`): a strip on top loading our own toolbar
//!   + tab bar page, served by Phoenix so it can call the `browser_*` Tauri
//!   commands.
//! - **content** (`browser-content-<sid>-<tabid>`): one webview per open tab,
//!   loading the external site. Each is in no capability, so loaded pages get no
//!   Tauri access. Exactly one content webview per surface is shown at a time
//!   (that surface's active tab); the rest are hidden but kept alive so switching
//!   is instant and state is preserved.
//!
//! The chrome JS owns the tab-strip UI and tab lifecycle; Rust owns the webviews
//! and the per-surface active-tab pointer (`BrowserState`) so navigate/back/
//! forward/reload and show-on-return act on the right tab without the chrome
//! re-passing it each time.

use std::collections::HashMap;
use std::sync::Mutex;
use tauri::webview::{PageLoadEvent, WebviewBuilder};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Url, WebviewUrl};

const CHROME_PREFIX: &str = "browser-chrome-"; // browser-chrome-<sid>
const CONTENT_PREFIX: &str = "browser-content-"; // browser-content-<sid>-<tabid>
const FIRST_TAB: &str = "1";
const DEFAULT_SID: &str = "main";
const CHROME_HEIGHT: f64 = 112.0; // tab strip (~34) + toolbar (46) + bookmark bar (32)

/// Per-surface active content tab id (the visible one for that surface). Managed
/// by Tauri so it survives across commands; the chrome JS keeps it in sync via
/// the tab commands.
#[derive(Default)]
pub struct BrowserState {
    // surface id -> active content tab id for that surface
    surfaces: Mutex<HashMap<String, String>>,
}

impl BrowserState {
    fn set(&self, sid: &str, tab_id: &str) {
        self.surfaces
            .lock()
            .unwrap()
            .insert(sid.to_string(), tab_id.to_string());
    }
    fn get(&self, sid: &str) -> Option<String> {
        self.surfaces.lock().unwrap().get(sid).cloned()
    }
    fn clear(&self, sid: &str) {
        self.surfaces.lock().unwrap().remove(sid);
    }
    fn clear_all(&self) {
        self.surfaces.lock().unwrap().clear();
    }
    // Any known surface — the default screenshot target when none is specified.
    fn any_sid(&self) -> Option<String> {
        self.surfaces.lock().unwrap().keys().next().cloned()
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

// Restrict surface ids to a hyphen-free alphanumeric alphabet so the
// `browser-content-<sid>-<tabid>` label parses unambiguously and per-surface
// prefix filtering is exact. Mirrors the dom-id sanitiser in split_live.ex.
fn sanitize_sid(sid: &str) -> String {
    let cleaned: String = sid.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if cleaned.is_empty() {
        DEFAULT_SID.to_string()
    } else {
        cleaned
    }
}

fn chrome_label(sid: &str) -> String {
    format!("{CHROME_PREFIX}{sid}")
}

fn content_label(sid: &str, tab_id: &str) -> String {
    format!("{CONTENT_PREFIX}{sid}-{tab_id}")
}

// All content webview labels belonging to one surface.
fn content_labels_for(app: &AppHandle, sid: &str) -> Vec<String> {
    let prefix = format!("{CONTENT_PREFIX}{sid}-");
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(&prefix))
        .cloned()
        .collect()
}

// Every browser-owned webview (all chromes + all content) across all surfaces,
// for global teardown.
fn all_browser_labels(app: &AppHandle) -> Vec<String> {
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(CHROME_PREFIX) || label.starts_with(CONTENT_PREFIX))
        .cloned()
        .collect()
}

/// Open a browser surface: ensure its chrome strip, then show its active content
/// tab (creating the first tab on a cold open, or re-showing the saved active tab
/// on return to `/browse` after `browser_hide`).
#[tauri::command]
pub fn browser_open(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    chrome_url: String,
    content_url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let chrome_h = CHROME_HEIGHT.min(height);
    let content_h = (height - chrome_h).max(0.0);
    let cy = y + chrome_h;

    ensure_chrome(&app, &sid, &chrome_url, x, y, width, chrome_h)?;

    // Pick the tab to show: the saved active one if it still exists, else any
    // existing content tab for this surface, else create the first tab.
    let labels = content_labels_for(&app, &sid);
    let active = state
        .get(&sid)
        .filter(|id| labels.contains(&content_label(&sid, id)));

    let content_prefix = format!("{CONTENT_PREFIX}{sid}-");
    let show_id = match active {
        Some(id) => id,
        None => match labels.first() {
            Some(label) => label.trim_start_matches(&content_prefix).to_string(),
            None => {
                create_content(&app, &sid, FIRST_TAB, &content_url, x, cy, width, content_h)?;
                FIRST_TAB.to_string()
            }
        },
    };

    state.set(&sid, &show_id);
    show_only(&app, &sid, &show_id, x, cy, width, content_h);
    Ok(())
}

/// Reposition/resize a surface's chrome + every content webview to track its box.
/// Does not change visibility (the active tab stays shown, hidden tabs stay hidden).
#[tauri::command]
pub fn browser_set_bounds(
    app: AppHandle,
    surface_id: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let chrome_h = CHROME_HEIGHT.min(height);
    let content_h = (height - chrome_h).max(0.0);
    let cy = y + chrome_h;

    let chrome = chrome_label(&sid);
    place(&app, &chrome, x, y, width, chrome_h);
    show(&app, &chrome);
    for label in content_labels_for(&app, &sid) {
        place(&app, &label, x, cy, width, content_h);
    }
    Ok(())
}

/// Open a new tab in a surface: create its content webview and make it the active
/// (visible) one. Bounds are copied from an existing content webview of the same
/// surface so it appears correctly placed.
#[tauri::command]
pub fn browser_new_tab(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
    url: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let (x, y, w, h) = sample_content_bounds(&app, &sid).ok_or("no content bounds yet")?;
    create_content(&app, &sid, &tab_id, &url, x, y, w, h)?;
    state.set(&sid, &tab_id);
    show_only(&app, &sid, &tab_id, x, y, w, h);
    Ok(())
}

/// Switch a surface's visible tab to `tab_id`.
#[tauri::command]
pub fn browser_switch_tab(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let (x, y, w, h) = sample_content_bounds(&app, &sid).unwrap_or((0.0, 0.0, 0.0, 0.0));
    state.set(&sid, &tab_id);
    show_only(&app, &sid, &tab_id, x, y, w, h);
    Ok(())
}

/// Close one tab's content webview in a surface. The chrome then switches to a
/// neighbour.
#[tauri::command]
pub fn browser_close_tab(app: AppHandle, surface_id: String, tab_id: String) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    if let Some(webview) = app.get_webview(&content_label(&sid, &tab_id)) {
        webview.close().map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Navigate a tab's content webview (called from a surface's chrome toolbar with
/// that chrome's active tab id). Falls back to the surface's active tab, then any
/// tab in the surface.
#[tauri::command]
pub fn browser_navigate(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
    url: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let Some(webview) = resolve_target(&app, &state, &sid, &tab_id) else {
        return Err(format!("no content webview for tab {tab_id}"));
    };
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;
    webview.navigate(parsed).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn browser_back(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    tab_eval(&app, &state, &sid, &tab_id, "history.back()")
}

#[tauri::command]
pub fn browser_forward(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    tab_eval(&app, &state, &sid, &tab_id, "history.forward()")
}

#[tauri::command]
pub fn browser_reload(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    tab_eval(&app, &state, &sid, &tab_id, "location.reload()")
}

/// Hide a surface's chrome + all its content webviews without destroying them —
/// used when leaving `/browse` so every tab persists when the user returns.
#[tauri::command]
pub fn browser_hide(app: AppHandle, surface_id: String) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let mut labels = content_labels_for(&app, &sid);
    labels.push(chrome_label(&sid));
    for label in labels {
        if let Some(webview) = app.get_webview(&label) {
            webview.hide().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// Tear a browser down entirely. With a `surface_id`, closes just that surface's
/// chrome + tabs; without one, closes **every** surface (the global teardown used
/// when the Browser tab is closed or a split containing a browser is left).
#[tauri::command]
pub fn browser_close(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
) -> Result<(), String> {
    let labels = match &surface_id {
        Some(raw) => {
            let sid = sanitize_sid(raw);
            let mut l = content_labels_for(&app, &sid);
            l.push(chrome_label(&sid));
            l
        }
        None => all_browser_labels(&app),
    };
    for label in labels {
        if let Some(webview) = app.get_webview(&label) {
            webview.close().map_err(|e| e.to_string())?;
        }
    }
    match &surface_id {
        Some(raw) => state.clear(&sanitize_sid(raw)),
        None => state.clear_all(),
    }
    Ok(())
}

/// Capture a surface's active content tab as a PNG. Returns base64-encoded bytes
/// plus the tab's current URL, so the agent gets a screenshot of what the user is
/// viewing. Without a `surface_id`, defaults to any open surface. macOS path uses
/// WKWebView's in-process `-takeSnapshot…` — no Screen-Recording permission
/// prompt. Errors if no browser tab is open.
#[tauri::command]
pub fn browser_screenshot(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
) -> Result<Screenshot, String> {
    let sid = surface_id
        .map(|s| sanitize_sid(&s))
        .or_else(|| state.any_sid())
        .unwrap_or_else(|| DEFAULT_SID.to_string());
    let id = state
        .get(&sid)
        .ok_or_else(|| "no active browser tab".to_string())?;
    let webview = app
        .get_webview(&content_label(&sid, &id))
        .ok_or_else(|| "active tab webview missing".to_string())?;

    let url = webview.url().map(|u| u.to_string()).unwrap_or_default();
    let png = capture_webview(&webview)?;

    use base64::Engine as _;
    Ok(Screenshot {
        data: base64::engine::general_purpose::STANDARD.encode(png),
        url,
    })
}

#[derive(serde::Serialize)]
pub struct Screenshot {
    /// Base64-encoded PNG bytes of the active tab.
    pub data: String,
    /// The active tab's current URL.
    pub url: String,
}

// WKWebView snapshot is async (completion handler); bridge it back to this
// (worker-thread) command over a channel. `with_webview` runs the closure on the
// main thread, which is free to fire the completion while we block on `recv`.
#[cfg(target_os = "macos")]
fn capture_webview(webview: &tauri::Webview) -> Result<Vec<u8>, String> {
    use block::ConcreteBlock;
    use objc::runtime::Object;
    use objc::{msg_send, sel, sel_impl};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel::<Result<Vec<u8>, String>>();

    webview
        .with_webview(move |pw| {
            let wk = pw.inner() as *mut Object;
            if wk.is_null() {
                let _ = tx.send(Err("null webview handle".into()));
                return;
            }

            let tx_block = tx.clone();
            let completion = ConcreteBlock::new(move |image: *mut Object, _err: *mut Object| {
                let result = if image.is_null() {
                    Err("snapshot returned nil".to_string())
                } else {
                    unsafe { nsimage_to_png(image) }
                };
                let _ = tx_block.send(result);
            });
            // Move the block to the heap; WKWebView copies/retains it for the
            // duration of the async call, so it outlives this closure.
            let completion = completion.copy();

            unsafe {
                let nil: *mut Object = std::ptr::null_mut();
                let _: () = msg_send![
                    wk,
                    takeSnapshotWithConfiguration: nil
                    completionHandler: &*completion
                ];
            }
        })
        .map_err(|e| e.to_string())?;

    match rx.recv_timeout(Duration::from_secs(8)) {
        Ok(result) => result,
        Err(_) => Err("screenshot timed out".into()),
    }
}

#[cfg(target_os = "macos")]
unsafe fn nsimage_to_png(image: *mut objc::runtime::Object) -> Result<Vec<u8>, String> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let tiff: *mut Object = msg_send![image, TIFFRepresentation];
    if tiff.is_null() {
        return Err("no TIFF representation".into());
    }
    let rep: *mut Object = msg_send![class!(NSBitmapImageRep), imageRepWithData: tiff];
    if rep.is_null() {
        return Err("no bitmap representation".into());
    }
    let props: *mut Object = msg_send![class!(NSDictionary), dictionary];
    // NSBitmapImageFileType.png == 4
    let png: *mut Object = msg_send![rep, representationUsingType: 4u64 properties: props];
    if png.is_null() {
        return Err("PNG encoding failed".into());
    }
    let len: usize = msg_send![png, length];
    let bytes: *const u8 = msg_send![png, bytes];
    if bytes.is_null() || len == 0 {
        return Err("empty PNG data".into());
    }
    Ok(std::slice::from_raw_parts(bytes, len).to_vec())
}

#[cfg(not(target_os = "macos"))]
fn capture_webview(_webview: &tauri::Webview) -> Result<Vec<u8>, String> {
    Err("browser_screenshot is only supported on macOS".into())
}

// --- internals ----------------------------------------------------------

// Show one content tab of a surface, hide every other in that surface;
// (re)position the shown one.
fn show_only(app: &AppHandle, sid: &str, tab_id: &str, x: f64, y: f64, w: f64, h: f64) {
    let target = content_label(sid, tab_id);
    for label in content_labels_for(app, sid) {
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

// Bounds of any existing content webview in this surface (so a new/switched tab
// lands correctly).
fn sample_content_bounds(app: &AppHandle, sid: &str) -> Option<(f64, f64, f64, f64)> {
    let label = content_labels_for(app, sid).into_iter().next()?;
    let webview = app.get_webview(&label)?;
    let pos = webview.position().ok()?;
    let size = webview.size().ok()?;
    let scale = app
        .get_window("main")
        .and_then(|w| w.scale_factor().ok())
        .unwrap_or(1.0);
    Some((
        pos.x as f64 / scale,
        pos.y as f64 / scale,
        size.width as f64 / scale,
        size.height as f64 / scale,
    ))
}

fn ensure_chrome(
    app: &AppHandle,
    sid: &str,
    url: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let label = chrome_label(sid);
    if app.get_webview(&label).is_some() {
        place(app, &label, x, y, width, height);
        show(app, &label);
        return Ok(());
    }
    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let parsed: Url = url.parse().map_err(|e| format!("invalid url {url}: {e}"))?;
    window
        .add_child(
            WebviewBuilder::new(&label, WebviewUrl::External(parsed)),
            LogicalPosition::new(x, y),
            LogicalSize::new(width, height),
        )
        .map_err(|e| format!("failed to create chrome: {e}"))?;
    Ok(())
}

// Create a content webview for `tab_id` in a surface with the navigation guard,
// popup guard, and per-tab navigation reporting back to that surface's chrome.
fn create_content(
    app: &AppHandle,
    sid: &str,
    tab_id: &str,
    url: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let label = content_label(sid, tab_id);
    if app.get_webview(&label).is_some() {
        return Ok(());
    }
    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let parsed: Url = url.parse().map_err(|e| format!("invalid url {url}: {e}"))?;

    let app_for_nav = app.clone();
    let id_for_nav = tab_id.to_string();
    let chrome_for_nav = chrome_label(sid);
    let app_for_load = app.clone();
    let id_for_load = tab_id.to_string();
    let chrome_for_load = chrome_label(sid);
    let builder = WebviewBuilder::new(&label, WebviewUrl::External(parsed))
        .on_navigation(move |url| {
            // Lock to web navigation: block file://, tauri://, javascript:, data:.
            let allowed = matches!(url.scheme(), "http" | "https") || url.as_str() == "about:blank";
            if allowed {
                // Fires *before* the page loads — tell the chrome this tab is now
                // loading (spinner + optimistic address-bar/url update). The real
                // title arrives on completion via `on_page_load` below.
                if let Some(chrome) = app_for_nav.get_webview(&chrome_for_nav) {
                    let _ = chrome.eval(&format!(
                        "window.__onContentLoading && window.__onContentLoading({}, {})",
                        js_str(&id_for_nav),
                        js_str(url.as_str())
                    ));
                }
            }
            allowed
        })
        .on_page_load(move |webview, payload| {
            // Fires when the page finishes loading — clear the spinner and hand
            // the chrome the real document title for the tab label.
            if payload.event() == PageLoadEvent::Finished {
                notify_navigated(
                    &app_for_load,
                    &chrome_for_load,
                    &id_for_load,
                    payload.url().as_str(),
                    &webview,
                );
            }
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

// The content webview to act on within a surface: the requested tab, else the
// surface's active tab, else any open tab in the surface. Keeps nav working even
// if the chrome/Rust active pointers briefly diverge.
fn resolve_target(
    app: &AppHandle,
    state: &State<BrowserState>,
    sid: &str,
    tab_id: &str,
) -> Option<tauri::Webview> {
    app.get_webview(&content_label(sid, tab_id))
        .or_else(|| {
            state
                .get(sid)
                .and_then(|id| app.get_webview(&content_label(sid, &id)))
        })
        .or_else(|| {
            content_labels_for(app, sid)
                .into_iter()
                .next()
                .and_then(|l| app.get_webview(&l))
        })
}

fn tab_eval(
    app: &AppHandle,
    state: &State<BrowserState>,
    sid: &str,
    tab_id: &str,
    js: &str,
) -> Result<(), String> {
    if let Some(webview) = resolve_target(app, state, sid, tab_id) {
        webview.eval(js).map_err(|e| e.to_string())?;
    }
    Ok(())
}

// Tell a surface's chrome that a tab finished loading, passing the page's real
// title so the tab label can show it (the chrome falls back to the hostname when
// the title is empty). The favicon is derived host-side in the chrome JS.
//
// macOS reads WKWebView's `title` directly (same in-process objc bridge the
// screenshot path uses); other platforms pass an empty title and the chrome
// keeps the hostname label.
#[cfg(target_os = "macos")]
fn notify_navigated(
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
                nsstring_to_string(ns)
            }
        };
        emit_navigated(&app, &chrome_label, &tab_id, &url, &title);
    });
}

#[cfg(not(target_os = "macos"))]
fn notify_navigated(
    app: &AppHandle,
    chrome_label: &str,
    tab_id: &str,
    url: &str,
    _content: &tauri::Webview,
) {
    emit_navigated(app, chrome_label, tab_id, url, "");
}

#[cfg(target_os = "macos")]
unsafe fn nsstring_to_string(ns: *mut objc::runtime::Object) -> String {
    use objc::{msg_send, sel, sel_impl};
    if ns.is_null() {
        return String::new();
    }
    let utf8: *const std::os::raw::c_char = msg_send![ns, UTF8String];
    if utf8.is_null() {
        return String::new();
    }
    std::ffi::CStr::from_ptr(utf8)
        .to_string_lossy()
        .into_owned()
}

fn emit_navigated(app: &AppHandle, chrome_label: &str, tab_id: &str, url: &str, title: &str) {
    if let Some(chrome) = app.get_webview(chrome_label) {
        let _ = chrome.eval(&format!(
            "window.__onContentNavigated && window.__onContentNavigated({}, {}, {})",
            js_str(tab_id),
            js_str(url),
            js_str(title)
        ));
    }
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
            // U+2028/U+2029 are valid in modern JS string literals but are line
            // terminators on older engines; escape them so a page-controlled title
            // can never break out of the eval'd literal.
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
