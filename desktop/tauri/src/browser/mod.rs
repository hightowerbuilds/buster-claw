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

use std::sync::atomic::{AtomicU64, Ordering};
use tauri::webview::WebviewBuilder;
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Url, WebviewUrl};

mod ffi;
mod geometry;
mod js;
mod labels;
mod notify;
mod state;
mod webviews;

use ffi::{apply_content_blocking, capture_webview, eval_with_result, webview_title};
use geometry::content_box;
pub(crate) use js::js_str;
use js::{
    click_js, error_data, extract_matches_js, fill_js, find_elements_js, wait_probe_js,
    wait_result_json, ActTarget, EXTRACT_PAGE_JS, NO_TARGET_DATA, READ_PAGE_JS,
};
use labels::{
    chrome_label, content_label, parse_web_url, sanitize_sid, CONTENT_PREFIX, DEFAULT_SID,
    FIRST_TAB,
};
use notify::ping_agent_activity;
pub use state::BrowserState;
use webviews::{
    all_browser_labels, all_content_labels, content_labels_for, create_content, enforce_tab_budget,
    ensure_chrome, place, render_settle_and_read, resolve_target, sample_content_bounds, show,
    show_only, tab_eval,
};

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
