//! The imperative shell: webview lifecycle and placement. Everything here is
//! loops and calls — decisions (which tabs to evict, which JS to run, what
//! geometry to apply) live in the pure modules and `state`, so this layer
//! stays too dumb to be wrong in interesting ways.

use std::collections::HashSet;

use tauri::webview::{DownloadEvent, PageLoadEvent, WebviewBuilder};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Url, WebviewUrl};

use super::ffi::{apply_content_blocking, eval_with_result};
use super::js::{js_str, POPUPS_AS_TABS_JS, READ_PAGE_JS, SCROLL_RESTORE_JS};
use super::labels::{chrome_label, content_label, parse_web_url, CHROME_PREFIX, CONTENT_PREFIX};
use super::notify::{notify_navigated, report_download};
use super::state::BrowserState;

// All content webview labels belonging to one surface.
pub(super) fn content_labels_for(app: &AppHandle, sid: &str) -> Vec<String> {
    let prefix = format!("{CONTENT_PREFIX}{sid}-");
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(&prefix))
        .cloned()
        .collect()
}

// Every browser-owned webview (all chromes + all content) across all surfaces,
// for global teardown.
pub(super) fn all_browser_labels(app: &AppHandle) -> Vec<String> {
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(CHROME_PREFIX) || label.starts_with(CONTENT_PREFIX))
        .cloned()
        .collect()
}

// Every content webview across all surfaces (content blocking applies to all).
pub(super) fn all_content_labels(app: &AppHandle) -> Vec<String> {
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(CONTENT_PREFIX))
        .cloned()
        .collect()
}

// Poll the document until it reports `complete` (or the budget runs out — a
// slow page still yields whatever has rendered by then), give SPA hydration a
// short settle, then read. Runs on the command's worker thread; each poll is a
// main-thread `evaluateJavaScript` round-trip via `eval_with_result`.
pub(super) fn render_settle_and_read(
    webview: &tauri::Webview,
    budget_ms: u64,
) -> Result<String, String> {
    use std::time::{Duration, Instant};
    let deadline = Instant::now() + Duration::from_millis(budget_ms.clamp(1_000, 20_000));
    loop {
        std::thread::sleep(Duration::from_millis(300));
        match eval_with_result(webview, "String(document.readyState)") {
            Ok(state) if state == "complete" => break,
            _ if Instant::now() >= deadline => break,
            _ => {}
        }
    }
    std::thread::sleep(Duration::from_millis(500));
    eval_with_result(webview, READ_PAGE_JS)
}

// --- internals ----------------------------------------------------------

// Show one content tab of a surface, hide every other in that surface;
// (re)position the shown one.
pub(super) fn show_only(app: &AppHandle, sid: &str, tab_id: &str, x: f64, y: f64, w: f64, h: f64) {
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

// Tab ids that currently have a live content webview in this surface.
pub(super) fn live_tab_ids(app: &AppHandle, sid: &str) -> HashSet<String> {
    let prefix = format!("{CONTENT_PREFIX}{sid}-");
    content_labels_for(app, sid)
        .iter()
        .map(|label| label.trim_start_matches(&prefix).to_string())
        .collect()
}

// Background-tab suspension: after `active_id` is made current, keep only the
// MAX_LIVE_TABS most-recently-used live content webviews; close the rest to cap
// the process-per-tab memory ceiling. The active tab and ephemeral tabs are
// never evicted. Evicting only drops the webview — the chrome keeps the chip and
// its saved URL, so switching back recreates it (browser_switch_tab reloads it).
pub(super) fn enforce_tab_budget(
    app: &AppHandle,
    state: &State<BrowserState>,
    sid: &str,
    active_id: &str,
) {
    state.touch(sid, active_id);
    let live = live_tab_ids(app, sid);
    for id in state.select_evictions(sid, &live, active_id) {
        if let Some(webview) = app.get_webview(&content_label(sid, &id)) {
            let _ = webview.close();
            if let Some(chrome) = app.get_webview(&chrome_label(sid)) {
                let _ = chrome.eval(format!(
                    "window.__onTabSuspended && window.__onTabSuspended({})",
                    js_str(&id)
                ));
            }
        }
    }
}

// Bounds of any existing content webview in this surface (so a new/switched tab
// lands correctly).
pub(super) fn sample_content_bounds(app: &AppHandle, sid: &str) -> Option<(f64, f64, f64, f64)> {
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

pub(super) fn ensure_chrome(
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
// Candidate for a params struct when this moves to webviews.rs (Phase 4 of the
// shell rebuild); not worth a signature churn while it lives in the monolith.
#[allow(clippy::too_many_arguments)]
pub(super) fn create_content(
    app: &AppHandle,
    sid: &str,
    tab_id: &str,
    url: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    ephemeral: bool,
    blocking: bool,
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
    let app_for_dl = app.clone();
    let chrome_for_dl = chrome_label(sid);
    // Ephemeral tabs (agent sandbox, Phase 3.4) get a non-persistent
    // WKWebsiteDataStore — no cookies/storage shared with the user session,
    // nothing persisted to disk. wry maps incognito to
    // WKWebsiteDataStore.nonPersistentDataStore on macOS.
    let builder = WebviewBuilder::new(&label, WebviewUrl::External(parsed))
        .incognito(ephemeral)
        // Downloads (a click on a PDF/zip/attachment): wry pre-fills
        // `destination` with a deduped ~/Downloads/<suggested> path — accept
        // it, log the file by id, and drive the chrome's download shelf. On
        // Finished (which carries no path on macOS) the log resolves the file
        // by URL for the shelf and the Sentinel report.
        .on_download(move |_webview, event| {
            let state = app_for_dl.state::<BrowserState>();
            match event {
                DownloadEvent::Requested { url, destination } => {
                    let id = state.download_started(url.as_str(), destination.clone());
                    let name = destination
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| "download".to_string());
                    if let Some(chrome) = app_for_dl.get_webview(&chrome_for_dl) {
                        let _ = chrome.eval(format!(
                            "window.__onDownloadStarted && window.__onDownloadStarted({id}, {})",
                            js_str(&name)
                        ));
                    }
                }
                DownloadEvent::Finished { url, success, .. } => {
                    if let Some((id, path)) = state.download_finished(url.as_str()) {
                        if let Some(chrome) = app_for_dl.get_webview(&chrome_for_dl) {
                            let _ = chrome.eval(format!(
                                "window.__onDownloadFinished && window.__onDownloadFinished({id}, {success})"
                            ));
                        }
                        report_download(&app_for_dl, &chrome_for_dl, url.as_str(), &path, success);
                    }
                }
                _ => {}
            }
            true
        })
        .on_navigation(move |url| {
            // Popup sentinel from POPUPS_AS_TABS_JS: cancel the navigation and
            // open the carried URL as a new tab via this surface's chrome, so
            // the tab strip stays in sync.
            if url.scheme() == "bcpopup" {
                let carried = url
                    .query_pairs()
                    .find(|(k, _)| k == "u")
                    .map(|(_, v)| v.into_owned());
                if let Some(Ok(target)) = carried.map(|u| parse_web_url(&u)) {
                    if let Some(chrome) = app_for_nav.get_webview(&chrome_for_nav) {
                        let _ = chrome.eval(format!(
                            "window.__agentOpenTab && window.__agentOpenTab({})",
                            js_str(target.as_str())
                        ));
                    }
                }
                return false;
            }
            // Lock to web navigation: block file://, tauri://, javascript:, data:.
            let allowed = matches!(url.scheme(), "http" | "https") || url.as_str() == "about:blank";
            if allowed {
                // Fires *before* the page loads — tell the chrome this tab is now
                // loading (spinner + optimistic address-bar/url update). The real
                // title arrives on completion via `on_page_load` below.
                if let Some(chrome) = app_for_nav.get_webview(&chrome_for_nav) {
                    let _ = chrome.eval(format!(
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
        .initialization_script(POPUPS_AS_TABS_JS)
        .initialization_script(SCROLL_RESTORE_JS);

    window
        .add_child(
            builder,
            LogicalPosition::new(x, y),
            LogicalSize::new(width, height),
        )
        .map_err(|e| format!("failed to create {label}: {e}"))?;

    // Attach native content blocking to the fresh webview (a no-op when off, so
    // the compiled rule list is never even looked up while blocking is disabled).
    if blocking {
        if let Some(webview) = app.get_webview(&label) {
            apply_content_blocking(&webview, true);
        }
    }
    Ok(())
}

// Move/resize without changing visibility.
pub(super) fn place(app: &AppHandle, label: &str, x: f64, y: f64, width: f64, height: f64) {
    if let Some(webview) = app.get_webview(label) {
        let _ = webview.set_position(LogicalPosition::new(x, y));
        let _ = webview.set_size(LogicalSize::new(width, height));
    }
}

pub(super) fn show(app: &AppHandle, label: &str) {
    if let Some(webview) = app.get_webview(label) {
        let _ = webview.show();
    }
}

// The content webview to act on within a surface: the requested tab, else the
// surface's active tab, else any open tab in the surface. Keeps nav working even
// if the chrome/Rust active pointers briefly diverge.
pub(super) fn resolve_target(
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

pub(super) fn tab_eval(
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
