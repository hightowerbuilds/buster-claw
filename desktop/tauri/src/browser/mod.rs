//! Embedded browser with a native tab system, instanceable per **surface**.
//!
//! A *surface* is one on-screen browser instance, keyed by a short id
//! (`"main"` for the solo `/browse`, `"left"`/`"right"` for the two panes of a
//! browser+browser split). Each surface is fully independent — its own chrome,
//! its own content tabs, its own active-tab pointer.
//!
//! - **chrome** (`browser-chrome-<sid>`): covers the surface's whole box,
//!   loading our own chrome page (top block: app tabs + toolbar + bookmark bar;
//!   left sidebar: the vertical browser-tab strip), served by Phoenix so it can
//!   call the `browser_*` Tauri commands. Its center region is permanently
//!   covered by the content webview (see `content_box`).
//! - **content** (`browser-content-<sid>-<tabid>`): one webview per open tab,
//!   loading the external site, inset below the chrome's top block and right of
//!   its sidebar. Each is in no capability, so loaded pages get no Tauri access.
//!   Exactly one content webview per surface is shown at a time (that surface's
//!   active tab); the rest are hidden but kept alive so switching is instant and
//!   state is preserved. Content webviews are always created after the chrome,
//!   which is what keeps them above it in NSView sibling (paint) order.
//!
//! The chrome JS owns the tab-strip UI and tab lifecycle; Rust owns the webviews
//! and the per-surface active-tab pointer (`BrowserState`) so navigate/back/
//! forward/reload and show-on-return act on the right tab without the chrome
//! re-passing it each time.

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::webview::{DownloadEvent, PageLoadEvent, WebviewBuilder};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Url, WebviewUrl};

mod geometry;
mod js;
mod labels;
mod state;

use geometry::content_box;
pub(crate) use js::js_str;
use js::{
    click_js, error_data, extract_matches_js, fill_js, find_elements_js, wait_probe_js,
    wait_result_json, ActTarget, EXTRACT_PAGE_JS, NO_TARGET_DATA, POPUPS_AS_TABS_JS, READ_PAGE_JS,
    SCROLL_RESTORE_JS,
};
use labels::{
    chrome_label, content_label, parse_web_url, sanitize_sid, CHROME_PREFIX, CONTENT_PREFIX,
    DEFAULT_SID, FIRST_TAB,
};
pub use state::BrowserState;

// Native content blocking (roadmap Phase 4). A curated EasyList subset of the
// highest-impact ad/tracker/analytics hosts, compiled once by WebKit's own
// WKContentRuleListStore and applied to every content webview — Safari's
// content-blocker engine, uniquely available to us because we chose WKWebView.
// Bump the identifier's version suffix whenever blocklist.json changes so the
// store recompiles instead of serving a stale cached list.
const BLOCKLIST_ID: &str = "buster-blocklist-v1";
#[cfg(target_os = "macos")]
const BLOCKLIST_JSON: &str = include_str!("../blocklist.json");

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

// Every content webview across all surfaces (content blocking applies to all).
fn all_content_labels(app: &AppHandle) -> Vec<String> {
    app.webviews()
        .keys()
        .filter(|label| label.starts_with(CONTENT_PREFIX))
        .cloned()
        .collect()
}

/// Open a browser surface: ensure its chrome strip, then show its active content
/// tab (creating the first tab on a cold open, or re-showing the saved active tab
/// on return to `/browse` after `browser_hide`).
#[tauri::command]
// The flat x/y/width/height params ARE the JS contract (camelCase invoke args
// from chrome.js/browser.js) — bundling them into a struct would rename them.
#[allow(clippy::too_many_arguments)]
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
    state.set_box(&sid, (x, y, width, height));
    let (cx, cy, content_w, content_h) =
        content_box(x, y, width, height, state.is_sidebar_collapsed(&sid));

    // Full box: the chrome paints the top block + tab sidebar; content covers
    // the rest (created later, so it stacks above the chrome's dead center).
    ensure_chrome(&app, &sid, &chrome_url, x, y, width, height)?;

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
                let blocking = state.content_blocking();
                create_content(
                    &app,
                    &sid,
                    FIRST_TAB,
                    &content_url,
                    cx,
                    cy,
                    content_w,
                    content_h,
                    false,
                    blocking,
                )?;
                FIRST_TAB.to_string()
            }
        },
    };

    state.set(&sid, &show_id);
    state.set_shown(&sid);
    show_only(&app, &sid, &show_id, cx, cy, content_w, content_h);
    enforce_tab_budget(&app, &state, &sid, &show_id);
    Ok(())
}

/// Reposition/resize a surface's chrome + every content webview to track its box.
/// Does not change visibility (the active tab stays shown, hidden tabs stay hidden).
#[tauri::command]
pub fn browser_set_bounds(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    state.set_box(&sid, (x, y, width, height));
    let (cx, cy, content_w, content_h) =
        content_box(x, y, width, height, state.is_sidebar_collapsed(&sid));

    state.set_shown(&sid);
    let chrome = chrome_label(&sid);
    place(&app, &chrome, x, y, width, height);
    show(&app, &chrome);
    for label in content_labels_for(&app, &sid) {
        place(&app, &label, cx, cy, content_w, content_h);
    }
    Ok(())
}

/// Collapse/expand a surface's tab sidebar (the chrome's bumper or ⌘B). The
/// chrome owns the preference and repaints itself via CSS; this re-insets the
/// content webviews to match, from the surface box saved by open/set_bounds.
#[tauri::command]
pub fn browser_set_sidebar(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    collapsed: bool,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    state.set_sidebar_collapsed(&sid, collapsed);

    if let Some((x, y, width, height)) = state.box_for(&sid) {
        let (cx, cy, content_w, content_h) = content_box(x, y, width, height, collapsed);
        for label in content_labels_for(&app, &sid) {
            place(&app, &label, cx, cy, content_w, content_h);
        }
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
    ephemeral: Option<bool>,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let is_ephemeral = ephemeral.unwrap_or(false);
    let (x, y, w, h) = sample_content_bounds(&app, &sid).ok_or("no content bounds yet")?;
    create_content(
        &app,
        &sid,
        &tab_id,
        &url,
        x,
        y,
        w,
        h,
        is_ephemeral,
        state.content_blocking(),
    )?;
    state.mark_ephemeral(&sid, &tab_id, is_ephemeral);
    state.set(&sid, &tab_id);
    show_only(&app, &sid, &tab_id, x, y, w, h);
    enforce_tab_budget(&app, &state, &sid, &tab_id);
    Ok(())
}

/// Switch a surface's visible tab to `tab_id`. If that tab was suspended
/// (background-tab eviction closed its webview), `url` — the chrome's saved
/// address for the chip — recreates it on demand so the switch-back reloads.
#[tauri::command]
pub fn browser_switch_tab(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
    url: Option<String>,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let (x, y, w, h) = sample_content_bounds(&app, &sid).unwrap_or((0.0, 0.0, 0.0, 0.0));
    // Resurrect a suspended tab: no webview, but the chrome still holds its URL.
    if app.get_webview(&content_label(&sid, &tab_id)).is_none() {
        if let Some(u) = url.as_deref().filter(|u| !u.is_empty()) {
            if w > 0.0 && h > 0.0 {
                create_content(
                    &app,
                    &sid,
                    &tab_id,
                    u,
                    x,
                    y,
                    w,
                    h,
                    false,
                    state.content_blocking(),
                )?;
            }
        }
    }
    state.set(&sid, &tab_id);
    show_only(&app, &sid, &tab_id, x, y, w, h);
    enforce_tab_budget(&app, &state, &sid, &tab_id);
    Ok(())
}

/// Close one tab's content webview in a surface. The chrome then switches to a
/// neighbour.
#[tauri::command]
pub fn browser_close_tab(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    state.forget(&sid, &tab_id);
    state.mark_ephemeral(&sid, &tab_id, false);
    if let Some(webview) = app.get_webview(&content_label(&sid, &tab_id)) {
        webview.close().map_err(|e| e.to_string())?;
    }
    // If we just closed the surface's active tab, advance the active pointer to a
    // surviving sibling (else clear it). Otherwise co-presence commands
    // (active_content → state.get) keep resolving to the just-closed label and
    // fail until the chrome's follow-up browser_switch_tab lands.
    if state.get(&sid).as_deref() == Some(tab_id.as_str()) {
        let closed = content_label(&sid, &tab_id);
        let prefix = format!("{CONTENT_PREFIX}{sid}-");
        let sibling = content_labels_for(&app, &sid)
            .into_iter()
            .find(|l| *l != closed)
            .map(|l| l.trim_start_matches(&prefix).to_string());
        match sibling {
            Some(next) => state.set(&sid, &next),
            None => state.unset(&sid),
        }
    }
    Ok(())
}

/// Toggle native content blocking for the whole browser. Persisted client-side by
/// the chrome (which re-syncs this on load); here it flips the session flag —
/// which future tabs read at creation — and applies/clears the rule list on every
/// live content webview immediately (taking visible effect on their next reload).
#[tauri::command]
pub fn browser_set_content_blocking(
    app: AppHandle,
    state: State<BrowserState>,
    enabled: bool,
) -> Result<(), String> {
    state.set_content_blocking(enabled);
    for label in all_content_labels(&app) {
        if let Some(webview) = app.get_webview(&label) {
            apply_content_blocking(&webview, enabled);
        }
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

/// Find-in-page (⌘F through the chrome's find bar): select the next/previous
/// match via WebKit's `window.find` — selection + scroll with wraparound.
/// Cheap but effective; match *counts* would need the native WKWebView find
/// API (an objc bridge for later, if ever missed).
#[tauri::command]
pub fn browser_find(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
    query: String,
    backwards: bool,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    if query.is_empty() {
        return Ok(());
    }
    let js = format!("window.find({}, false, {backwards}, true)", js_str(&query));
    tab_eval(&app, &state, &sid, &tab_id, &js)
}

/// Total match count for the chrome's find bar ("N matches"): counts
/// case-insensitive occurrences of `query` in the page's rendered `innerText`.
/// An approximation of what `window.find` steps through (innerText already
/// excludes hidden text), but cheap and honest enough for a count label —
/// positional "3 of 17" tracking would need the native WKWebView find API.
#[tauri::command]
pub async fn browser_find_count(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: String,
    tab_id: String,
    query: String,
) -> Result<u32, String> {
    let sid = sanitize_sid(&surface_id);
    if query.is_empty() {
        return Ok(0);
    }
    let webview =
        resolve_target(&app, &state, &sid, &tab_id).ok_or_else(|| "no such tab".to_string())?;
    let js = format!(
        r#"String((function () {{
  var q = {}.toLowerCase();
  if (!q) return 0;
  var t = ((document.body && document.body.innerText) || "").toLowerCase();
  var c = 0, i = 0;
  while ((i = t.indexOf(q, i)) !== -1) {{ c++; i += q.length; if (c > 9999) break; }}
  return c;
}})())"#,
        js_str(&query)
    );
    let raw = eval_with_result(&webview, &js)?;
    raw.trim()
        .parse::<u32>()
        .map_err(|_| "bad match count".to_string())
}

/// Set a content tab's page zoom (⌘+/⌘−/⌘0 through the chrome). The chrome
/// tracks the per-tab factor; this just applies it, clamped to a sane range.
#[tauri::command]
pub fn browser_set_zoom(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
    tab_id: String,
    factor: f64,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let factor = factor.clamp(0.25, 5.0);
    let Some(webview) = resolve_target(&app, &state, &sid, &tab_id) else {
        return Err(format!("no content webview for tab {tab_id}"));
    };
    webview.set_zoom(factor).map_err(|e| e.to_string())
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
pub fn browser_hide(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: String,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    state.set_hidden(&sid);
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
pub async fn browser_screenshot(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
) -> Result<Screenshot, String> {
    let webview = active_content(&app, &state, surface_id)?;

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

/// The active content tab's URL + page title, for agent co-presence.
#[derive(serde::Serialize)]
pub struct CurrentTab {
    pub url: String,
    pub title: String,
}

/// Read the active content tab the user is viewing. Without a `surface_id`,
/// defaults to any open surface. Returns the tab's current URL + page title.
#[tauri::command]
pub fn browser_current(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
) -> Result<CurrentTab, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "reading");
    let webview = active_content(&app, &state, surface_id)?;
    let url = webview.url().map(|u| u.to_string()).unwrap_or_default();
    let title = webview_title(&webview).unwrap_or_default();
    Ok(CurrentTab { url, title })
}

/// The page the user is viewing, read from the **rendered DOM** of the active
/// content tab (agent co-presence). Unlike the server-side fetch pipeline,
/// this sees the page as the user's session sees it — logged-in views
/// included; the Phoenix command layer records the Sentinel event for that.
/// Returns `{data}`: a JSON string of `{url, title, text, links}`.
#[tauri::command]
pub async fn browser_read_active(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
) -> Result<ReadPage, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "reading");
    let webview = active_content(&app, &state, surface_id)?;
    let data = eval_with_result(&webview, READ_PAGE_JS)?;
    Ok(ReadPage { data })
}

#[derive(serde::Serialize)]
pub struct ReadPage {
    /// JSON-encoded `{url, title, text, links}` straight from the page script.
    pub data: String,
}

// Off-screen render webview labels — unique per render so concurrent renders
// never collide.
static RENDER_SEQ: AtomicU64 = AtomicU64::new(0);

/// Server-side fetch fallback for JS-heavy pages (packaged builds carry no
/// Playwright sidecar): load `url` in a hidden, **ephemeral** child webview
/// (non-persistent data store — never the user's cookies or session), wait for
/// the document to finish loading plus a short hydration settle, run the same
/// read script `browser_read_active` uses, and close the webview. The Phoenix
/// `Browser` module decides *when* a render is worth it; this command just
/// renders. Returns `{data}` in the `browser_read_active` shape.
#[tauri::command]
pub async fn browser_render_page(
    app: AppHandle,
    url: String,
    wait_ms: Option<u64>,
) -> Result<ReadPage, String> {
    let parsed = parse_web_url(&url)?;
    let window = app
        .get_window("main")
        .ok_or_else(|| "main window missing".to_string())?;
    let label = format!(
        "browser-render-{}",
        RENDER_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    // Parked far off-screen: laid out and rendered (so innerText is real) but
    // never visible and never focused. Viewport-sized so pages don't collapse
    // into a degenerate layout.
    let builder = WebviewBuilder::new(&label, WebviewUrl::External(parsed))
        .incognito(true)
        .focused(false);
    let webview = window
        .add_child(
            builder,
            LogicalPosition::new(-4000.0, 0.0),
            LogicalSize::new(1100.0, 900.0),
        )
        .map_err(|e| format!("failed to create {label}: {e}"))?;
    let result = render_settle_and_read(&webview, wait_ms.unwrap_or(9_000));
    let _ = webview.close();
    result.map(|data| ReadPage { data })
}

// Poll the document until it reports `complete` (or the budget runs out — a
// slow page still yields whatever has rendered by then), give SPA hydration a
// short settle, then read. Runs on the command's worker thread; each poll is a
// main-thread `evaluateJavaScript` round-trip via `eval_with_result`.
fn render_settle_and_read(webview: &tauri::Webview, budget_ms: u64) -> Result<String, String> {
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

/// A JSON string result from an interaction script run in the active tab.
#[derive(serde::Serialize)]
pub struct EvalData {
    pub data: String,
}

/// List the visible interactive elements of the active content tab (agent
/// co-presence) and register them in the page's `window.__bcEls` for
/// `browser_click_active` / `browser_fill_active`. Returns `{data}`: a JSON
/// string of `[{i, tag, type, label, value, href}]`.
#[tauri::command]
pub async fn browser_find_elements_active(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
    query: Option<String>,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "scanning");
    let webview = active_content(&app, &state, surface_id)?;
    let js = find_elements_js(query.as_deref().unwrap_or(""));
    let data = eval_with_result(&webview, &js)?;
    Ok(EvalData { data })
}

/// Click an element in the active tab (agent co-presence — acts inside the
/// user's live session). Target: `selector` (querySelector), else `text`
/// (exact-then-substring match on visible actionable elements), else the
/// legacy `index` into the tab's `window.__bcEls` registry. Returns `{data}`:
/// a JSON string of `{ok, label, matched_by}` or `{ok: false, error}`.
#[tauri::command]
pub async fn browser_click_active(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
    index: Option<usize>,
    selector: Option<String>,
    text: Option<String>,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "clicking");
    let Some(target) = ActTarget::from_params(index, selector, text) else {
        return Ok(EvalData {
            data: NO_TARGET_DATA.to_string(),
        });
    };
    let webview = active_content(&app, &state, surface_id)?;
    let data = eval_with_result(&webview, &click_js(&target))?;
    Ok(EvalData { data })
}

/// Fill an element in the active tab with `value`, dispatching bubbling
/// `input` + `change` events so framework listeners notice (agent co-presence
/// — acts inside the user's live session). Target resolution as in
/// `browser_click_active`. Returns `{data}`: a JSON string of
/// `{ok, label, matched_by}` or `{ok: false, error}`.
#[tauri::command]
pub async fn browser_fill_active(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
    index: Option<usize>,
    selector: Option<String>,
    text: Option<String>,
    value: String,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "typing");
    let Some(target) = ActTarget::from_params(index, selector, text) else {
        return Ok(EvalData {
            data: NO_TARGET_DATA.to_string(),
        });
    };
    let webview = active_content(&app, &state, surface_id)?;
    let data = eval_with_result(&webview, &fill_js(&target, &value))?;
    Ok(EvalData { data })
}

/// Wait until the active content tab satisfies `condition`, polling a tiny
/// probe script inside Rust every 250ms (the `render_settle_and_read`
/// precedent) up to `timeout_ms` (clamped 250..30_000, default 10_000).
/// Conditions: "navigation" (readyState complete, re-confirmed 400ms later),
/// "selector" (`value` matches), "visible" (`value` matches something with a
/// non-zero, non-hidden rect), "text" (`value` appears in the page's
/// innerText). Returns `{data}`: a JSON string of
/// `{ok, matched, waited_ms, condition}` — an exhausted budget is
/// `matched: false`, not an error; a bad condition/missing value is
/// `{ok: false, error}`.
#[tauri::command]
pub async fn browser_wait_active(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
    condition: String,
    value: Option<String>,
    timeout_ms: Option<u64>,
) -> Result<EvalData, String> {
    use std::time::{Duration, Instant};

    ping_agent_activity(&app, &state, surface_id.clone(), "waiting");
    let webview = active_content(&app, &state, surface_id)?;
    let probe = match wait_probe_js(&condition, value.as_deref()) {
        Ok(probe) => probe,
        Err(msg) => {
            return Ok(EvalData {
                data: error_data(&msg),
            })
        }
    };

    let started = Instant::now();
    let deadline = started + Duration::from_millis(timeout_ms.unwrap_or(10_000).clamp(250, 30_000));
    let mut matched = false;
    loop {
        match eval_with_result(&webview, &probe) {
            Ok(r) if r == "1" => {
                // "navigation" re-confirms once 400ms later: readyState can
                // read "complete" on the OLD page just before a click-driven
                // navigation starts.
                if condition != "navigation" {
                    matched = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(400));
                if matches!(eval_with_result(&webview, &probe).as_deref(), Ok("1")) {
                    matched = true;
                    break;
                }
            }
            Ok(r) if r == "e" => {
                return Ok(EvalData {
                    data: error_data("invalid selector"),
                })
            }
            // Not there yet — or the eval failed mid-navigation; keep polling.
            _ => {}
        }
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    let waited_ms = started.elapsed().as_millis();
    Ok(EvalData {
        data: wait_result_json(matched, waited_ms, &condition),
    })
}

/// Structured extraction from the active content tab (agent co-presence).
/// Without a `selector`: the whole page as `{ok, url, title, text}`. With
/// one: up to 50 matches as `{ok, count, matches: [{text, href?, value?,
/// attr?}]}` — `attr` names an attribute to read per match. Returns `{data}`:
/// a JSON string in either shape.
#[tauri::command]
pub async fn browser_extract_active(
    app: AppHandle,
    state: State<'_, BrowserState>,
    surface_id: Option<String>,
    selector: Option<String>,
    attr: Option<String>,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "reading");
    let webview = active_content(&app, &state, surface_id)?;
    let js = match selector.as_deref() {
        Some(sel) => extract_matches_js(sel, attr.as_deref()),
        None => EXTRACT_PAGE_JS.to_string(),
    };
    let data = eval_with_result(&webview, &js)?;
    Ok(EvalData { data })
}

// Run JS in a webview and return its (string) result — the completion-handler
// variant of `eval`. Same objc bridge pattern as the screenshot/title paths:
// THREADING CONTRACT: callers must be `async` commands (tokio worker), never
// sync ones. In Tauri 2 sync commands run ON the main thread; from there
// `with_webview` executes inline and `evaluateJavaScript` gets called, but its
// completion is delivered by the main run loop — which this recv is blocking.
// The completion can then never arrive and every call times out (observed live
// via `sample`: recv_timeout parked on DispatchQueue_1). From a worker thread
// the closure is dispatched to a free main loop and the round-trip completes.
#[cfg(target_os = "macos")]
fn eval_with_result(webview: &tauri::Webview, js: &str) -> Result<String, String> {
    use block::ConcreteBlock;
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel::<Result<String, String>>();
    let js = std::ffi::CString::new(js).map_err(|e| e.to_string())?;

    webview
        .with_webview(move |pw| {
            let wk = pw.inner() as *mut Object;
            if wk.is_null() {
                let _ = tx.send(Err("null webview handle".into()));
                return;
            }
            let tx_block = tx.clone();
            let completion = ConcreteBlock::new(move |result: *mut Object, error: *mut Object| {
                let out = if !error.is_null() {
                    Err("page script failed".to_string())
                } else if result.is_null() {
                    Err("page returned no result".to_string())
                } else {
                    unsafe { nsstring_to_string(result) }
                        .ok_or_else(|| "page returned a non-string result".to_string())
                };
                let _ = tx_block.send(out);
            });
            let completion = completion.copy();
            unsafe {
                let ns_js: *mut Object =
                    msg_send![class!(NSString), stringWithUTF8String: js.as_ptr()];
                let _: () = msg_send![
                    wk,
                    evaluateJavaScript: ns_js
                    completionHandler: &*completion
                ];
            }
        })
        .map_err(|e| e.to_string())?;

    match rx.recv_timeout(Duration::from_secs(6)) {
        Ok(result) => result,
        Err(_) => Err("page read timed out".into()),
    }
}

#[cfg(not(target_os = "macos"))]
fn eval_with_result(_webview: &tauri::Webview, _js: &str) -> Result<String, String> {
    Err("browser_read_active is only supported on macOS".into())
}

// Apply (or clear) native content blocking on one content webview via WebKit's
// WKContentRuleListStore — Safari's own content-blocker engine. When enabling,
// compile the curated blocklist (the store caches the compiled result on disk by
// identifier, so this is fast after the first tab) and add it to the webview's
// user-content controller; when disabling, drop all rule lists. Rule-list changes
// take effect on the next resource load, so a live page reflects a toggle on
// reload. Fire-and-forget: compilation completes on the main thread after this
// (worker-thread) call returns.
#[cfg(target_os = "macos")]
fn apply_content_blocking(webview: &tauri::Webview, enabled: bool) {
    use block::ConcreteBlock;
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let ident = match std::ffi::CString::new(BLOCKLIST_ID) {
        Ok(c) => c,
        Err(_) => return,
    };
    let json = std::ffi::CString::new(BLOCKLIST_JSON).ok();

    let _ = webview.with_webview(move |pw| {
        let wk = pw.inner() as *mut Object;
        if wk.is_null() {
            return;
        }
        unsafe {
            let config: *mut Object = msg_send![wk, configuration];
            let ucc: *mut Object = msg_send![config, userContentController];
            if ucc.is_null() {
                return;
            }
            if !enabled {
                let _: () = msg_send![ucc, removeAllContentRuleLists];
                return;
            }
            let Some(json) = json else { return };
            let store: *mut Object = msg_send![class!(WKContentRuleListStore), defaultStore];
            if store.is_null() {
                return;
            }
            let ns_id: *mut Object =
                msg_send![class!(NSString), stringWithUTF8String: ident.as_ptr()];
            let ns_json: *mut Object =
                msg_send![class!(NSString), stringWithUTF8String: json.as_ptr()];
            // The completion fires (async) on the main thread; capture the
            // controller by address (raw pointers aren't Send) and retain it so a
            // tab closed mid-compile can't free it out from under the add. WebKit
            // guarantees the completion runs, so the paired release always fires.
            let _: *mut Object = msg_send![ucc, retain];
            let ucc_addr = ucc as usize;
            let completion = ConcreteBlock::new(move |list: *mut Object, err: *mut Object| {
                let ucc = ucc_addr as *mut Object;
                if err.is_null() && !list.is_null() {
                    let _: () = msg_send![ucc, addContentRuleList: list];
                }
                let _: () = msg_send![ucc, release];
            });
            let completion = completion.copy();
            let _: () = msg_send![store,
                compileContentRuleListForIdentifier: ns_id
                encodedContentRuleList: ns_json
                completionHandler: &*completion];
        }
    });
}

#[cfg(not(target_os = "macos"))]
fn apply_content_blocking(_webview: &tauri::Webview, _enabled: bool) {}

/// Navigate the active content tab to `url` (agent-driven co-presence). The
/// surface's chrome updates its address bar/tab label via the on_navigation
/// callback fired for the content webview. Without a `surface_id`, defaults to
/// any open surface. Only http(s) URLs are allowed.
#[tauri::command]
pub fn browser_navigate_active(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
    url: String,
) -> Result<(), String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "navigating");
    let parsed = parse_web_url(&url)?;
    let webview = active_content(&app, &state, surface_id)?;
    webview.navigate(parsed).map_err(|e| e.to_string())
}

/// Open a new tab at `url` in the active surface and make it active. Routed
/// through that surface's chrome (`window.__agentOpenTab`) so its tab strip
/// stays in sync. Without a `surface_id`, defaults to any open surface. Only
/// http(s) URLs are allowed.
#[tauri::command]
pub fn browser_open_tab_active(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
    url: String,
    session: Option<String>,
) -> Result<(), String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "opening a tab");
    let parsed = parse_web_url(&url)?;
    // Agent sandbox tabs (roadmap Phase 3.4): agent-opened tabs get an
    // ephemeral, non-persistent data store BY DEFAULT — agent work doesn't
    // ride the user's cookies unless session == "user" grants it explicitly.
    let ephemeral = session.as_deref() != Some("user");
    let sid = active_sid(&state, surface_id);
    let chrome = app
        .get_webview(&chrome_label(&sid))
        .ok_or_else(|| "no browser surface open".to_string())?;
    chrome
        .eval(format!(
            "window.__agentOpenTab && window.__agentOpenTab({}, {ephemeral})",
            js_str(parsed.as_str())
        ))
        .map_err(|e| e.to_string())
}

// Report a finished download to Phoenix (`POST /browser/download`) so it lands
// on the Sentinel audit feed — a download pulls untrusted bytes onto disk, the
// one browser ingress the server-side fetch pipeline never sees.
fn report_download(app: &AppHandle, chrome_label: &str, url: &str, file: &Path, success: bool) {
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

/// Reveal a downloaded file in the Finder. Paths are resolved from the
/// session's download log by id — the chrome can never pass a raw path, so a
/// hostile page title/URL can't turn this into an arbitrary-path probe.
#[tauri::command]
pub fn browser_reveal_download(state: State<BrowserState>, download_id: u64) -> Result<(), String> {
    let path = state
        .download_path(download_id)
        .ok_or_else(|| "unknown download".to_string())?;
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("-R")
            .arg(&path)
            .spawn()
            .map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
        Err("reveal is only supported on macOS".into())
    }
}

/// Route a native menu accelerator (menu item ids `bc_<action>`) to the right
/// webview: the shown browser surface's chrome (`window.__menuShortcut`) when
/// one is on-screen, else the app webview (`window.__bcMenuShortcut`, handled
/// by the TabStrip hook) so app-tab shortcuts keep working outside the
/// browser. Menu accelerators fire regardless of webview focus (see the
/// build_app_menu doc in main.rs), so this router is the single owner of the
/// bound keys.
pub fn handle_menu_shortcut(app: &AppHandle, id: &str) {
    let Some(action) = id.strip_prefix("bc_") else {
        return;
    };
    let state: State<BrowserState> = app.state();
    let chrome = state
        .any_shown()
        .and_then(|sid| app.get_webview(&chrome_label(&sid)));
    let (webview, hook) = match chrome {
        Some(w) => (w, "__menuShortcut"),
        None => match app.get_webview("main") {
            Some(w) => (w, "__bcMenuShortcut"),
            None => return,
        },
    };
    let _ = webview.eval(format!(
        "window.{hook} && window.{hook}({})",
        js_str(action)
    ));
}

/// Navigate the app's **main** webview (the Phoenix UI) to an app route.
/// Backs the chrome's app-tab switcher: the native browser webviews cover the
/// DOM tab strip, so the chrome renders its own Home/app-tab chips and drives
/// the app through this. Only same-origin absolute paths are allowed —
/// `path` must start with `/` (and not `//`, which the URL parser would treat
/// as a protocol-relative external URL).
#[tauri::command]
pub fn browser_app_navigate(app: AppHandle, path: String) -> Result<(), String> {
    if !path.starts_with('/') || path.starts_with("//") {
        return Err("only absolute app paths are allowed".into());
    }
    let main = app
        .get_webview("main")
        .ok_or_else(|| "main webview missing".to_string())?;
    main.eval(format!("window.location.href = {}", js_str(&path)))
        .map_err(|e| e.to_string())
}

// The surface to act on: the requested one (sanitised), else any open surface,
// else the default.
fn active_sid(state: &State<BrowserState>, surface_id: Option<String>) -> String {
    surface_id
        .map(|s| sanitize_sid(&s))
        .or_else(|| state.any_sid())
        .unwrap_or_else(|| DEFAULT_SID.to_string())
}

// The active content webview of the resolved surface (the tab the user sees).
fn active_content(
    app: &AppHandle,
    state: &State<BrowserState>,
    surface_id: Option<String>,
) -> Result<tauri::Webview, String> {
    let sid = active_sid(state, surface_id);
    let id = state
        .get(&sid)
        .ok_or_else(|| "no active browser tab".to_string())?;
    app.get_webview(&content_label(&sid, &id))
        .ok_or_else(|| "active tab webview missing".to_string())
}

// Flash the co-presence badge in the surface's chrome so the user always sees
// when the agent has its hands on their live tab (trust is the product). Best
// effort — a closed browser (no chrome) is a silent no-op. Each co-presence
// command pings this at the top; the chrome shows the badge and auto-fades.
fn ping_agent_activity(
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

// Read a content webview's page title. macOS reads WKWebView's `title` property
// on the main thread (mirrors the screenshot snapshot bridge).
#[cfg(target_os = "macos")]
fn webview_title(webview: &tauri::Webview) -> Option<String> {
    use objc::runtime::Object;
    use objc::{msg_send, sel, sel_impl};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel::<Option<String>>();
    webview
        .with_webview(move |pw| {
            let wk = pw.inner() as *mut Object;
            let title = if wk.is_null() {
                None
            } else {
                unsafe {
                    let ns: *mut Object = msg_send![wk, title];
                    nsstring_to_string(ns)
                }
            };
            let _ = tx.send(title);
        })
        .ok()?;

    rx.recv_timeout(Duration::from_secs(2)).ok().flatten()
}

#[cfg(target_os = "macos")]
unsafe fn nsstring_to_string(s: *mut objc::runtime::Object) -> Option<String> {
    use objc::{msg_send, sel, sel_impl};

    if s.is_null() {
        return None;
    }
    let utf8: *const std::os::raw::c_char = msg_send![s, UTF8String];
    if utf8.is_null() {
        return None;
    }
    std::ffi::CStr::from_ptr(utf8)
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

#[cfg(not(target_os = "macos"))]
fn webview_title(_webview: &tauri::Webview) -> Option<String> {
    None
}

// WKWebView snapshot is async (completion handler); bridge it back to this
// (worker-thread) command over a channel. `with_webview` runs the closure on the
// main thread, which is free to fire the completion while we block on `recv`.
#[cfg(target_os = "macos")]
// Same threading contract as `eval_with_result`: the caller must be an async
// command — a sync (main-thread) caller blocks the run loop that must deliver
// the snapshot completion, and every capture times out.
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

// Tab ids that currently have a live content webview in this surface.
fn live_tab_ids(app: &AppHandle, sid: &str) -> HashSet<String> {
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
fn enforce_tab_budget(app: &AppHandle, state: &State<BrowserState>, sid: &str, active_id: &str) {
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
// Candidate for a params struct when this moves to webviews.rs (Phase 4 of the
// shell rebuild); not worth a signature churn while it lives in the monolith.
#[allow(clippy::too_many_arguments)]
fn create_content(
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
                nsstring_to_string(ns).unwrap_or_default()
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

fn emit_navigated(app: &AppHandle, chrome_label: &str, tab_id: &str, url: &str, title: &str) {
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

fn record_history(app: &AppHandle, chrome_label: &str, url: &str, title: &str) {
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

#[cfg(test)]
mod tests {
    use super::*;

    // ---- Characterization freeze (07-21, shell-rebuild Phase 0). Everything
    // below asserts OBSERVED behavior ahead of the browser/ module split; an
    // intentional behavior change must update these knowingly, and a module
    // move must pass them unmodified.

    // web.ex's decoders and the ScreenshotBridge JS read these field names
    // (shot.data/shot.url, cur.url/cur.title, page.data, res.data). Renaming a
    // field is a cross-language breaking change, not a refactor.
    #[test]
    fn return_structs_serialize_with_contract_field_names() {
        let v = serde_json::to_value(EvalData { data: "x".into() }).unwrap();
        assert_eq!(v, serde_json::json!({"data": "x"}));

        let v = serde_json::to_value(ReadPage { data: "y".into() }).unwrap();
        assert_eq!(v, serde_json::json!({"data": "y"}));

        let v = serde_json::to_value(Screenshot {
            data: "p".into(),
            url: "u".into(),
        })
        .unwrap();
        assert_eq!(v, serde_json::json!({"data": "p", "url": "u"}));

        let v = serde_json::to_value(CurrentTab {
            url: "u".into(),
            title: "t".into(),
        })
        .unwrap();
        assert_eq!(v, serde_json::json!({"url": "u", "title": "t"}));
    }
}
