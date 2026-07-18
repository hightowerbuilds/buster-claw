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

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::webview::{DownloadEvent, PageLoadEvent, WebviewBuilder};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, Url, WebviewUrl};

const CHROME_PREFIX: &str = "browser-chrome-"; // browser-chrome-<sid>
const CONTENT_PREFIX: &str = "browser-content-"; // browser-content-<sid>-<tabid>
const FIRST_TAB: &str = "1";
const DEFAULT_SID: &str = "main";
const CHROME_HEIGHT: f64 = 112.0; // tab strip (~34) + toolbar (46) + bookmark bar (32)

// Native content blocking (roadmap Phase 4). A curated EasyList subset of the
// highest-impact ad/tracker/analytics hosts, compiled once by WebKit's own
// WKContentRuleListStore and applied to every content webview — Safari's
// content-blocker engine, uniquely available to us because we chose WKWebView.
// Bump the identifier's version suffix whenever blocklist.json changes so the
// store recompiles instead of serving a stale cached list.
const BLOCKLIST_ID: &str = "buster-blocklist-v1";
#[cfg(target_os = "macos")]
const BLOCKLIST_JSON: &str = include_str!("blocklist.json");

/// Per-surface active content tab id (the visible one for that surface). Managed
/// by Tauri so it survives across commands; the chrome JS keeps it in sync via
/// the tab commands.
#[derive(Default)]
pub struct BrowserState {
    // surface id -> active content tab id for that surface
    surfaces: Mutex<HashMap<String, String>>,
    // Surfaces currently shown on-screen (open/set_bounds mark, hide/close
    // unmark). Menu accelerators route to a shown surface's chrome; when this
    // is empty the shortcut falls through to the app webview instead.
    shown: Mutex<HashSet<String>>,
    // Files the content webviews downloaded this session. The chrome's shelf
    // reveals them by id (never by a page-supplied path), and Finished events
    // — which carry no path on macOS — resolve their file here by URL.
    downloads: Mutex<DownloadLog>,
    // surface id -> tab ids in most-recently-active order (front = most recent).
    // The LRU key for background-tab suspension: live content webviews beyond
    // MAX_LIVE_TABS get evicted least-recent-first (the chip survives; a
    // switch-back reloads). See enforce_tab_budget.
    mru: Mutex<HashMap<String, Vec<String>>>,
    // Content labels of ephemeral (agent sandbox) tabs. Never suspended: their
    // non-persistent data store can't survive an evict→reload round-trip, so
    // dropping the webview would silently lose the session it promised to keep.
    ephemeral: Mutex<HashSet<String>>,
    // Content blocking is ON by default. We store the *disabled* flag so the
    // derived Default (false) means enabled; toggled by browser_set_content_blocking.
    blocking_disabled: AtomicBool,
}

// How many content webviews may stay live per surface before the least-recently
// used ones are suspended. Caps the process-per-tab memory ceiling; the tab chip
// (and its saved URL) survives, so a switch-back just reloads.
const MAX_LIVE_TABS: usize = 6;

#[derive(Default)]
struct DownloadLog {
    items: Vec<DownloadItem>,
    next_id: u64,
}

struct DownloadItem {
    id: u64,
    url: String,
    path: PathBuf,
    finished: bool,
}

impl BrowserState {
    fn set(&self, sid: &str, tab_id: &str) {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(sid.to_string(), tab_id.to_string());
    }
    fn get(&self, sid: &str) -> Option<String> {
        self.surfaces.lock().unwrap_or_else(|e| e.into_inner()).get(sid).cloned()
    }
    // Drop just the active-tab pointer for a surface (its chrome + other state
    // survive). Used when the active tab is closed and no sibling remains.
    fn unset(&self, sid: &str) {
        self.surfaces.lock().unwrap_or_else(|e| e.into_inner()).remove(sid);
    }
    fn clear(&self, sid: &str) {
        self.surfaces.lock().unwrap_or_else(|e| e.into_inner()).remove(sid);
        self.shown.lock().unwrap_or_else(|e| e.into_inner()).remove(sid);
        self.mru.lock().unwrap_or_else(|e| e.into_inner()).remove(sid);
        let prefix = format!("{CONTENT_PREFIX}{sid}-");
        self.ephemeral.lock().unwrap_or_else(|e| e.into_inner()).retain(|l| !l.starts_with(&prefix));
    }
    fn clear_all(&self) {
        self.surfaces.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.shown.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.mru.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.ephemeral.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }
    // Mark a tab most-recently-used (front of its surface's LRU list).
    fn touch(&self, sid: &str, tab_id: &str) {
        let mut mru = self.mru.lock().unwrap_or_else(|e| e.into_inner());
        let list = mru.entry(sid.to_string()).or_default();
        list.retain(|id| id != tab_id);
        list.insert(0, tab_id.to_string());
    }
    // Drop a tab from the LRU list (its chip was closed).
    fn forget(&self, sid: &str, tab_id: &str) {
        if let Some(list) = self.mru.lock().unwrap_or_else(|e| e.into_inner()).get_mut(sid) {
            list.retain(|id| id != tab_id);
        }
    }
    // Live tab ids for a surface, ordered most-recently-used first. `live` is the
    // set of tab ids that currently have a webview; MRU order drives which of them
    // to keep when the budget is exceeded.
    fn live_by_recency(&self, sid: &str, live: &HashSet<String>) -> Vec<String> {
        let mru = self.mru.lock().unwrap_or_else(|e| e.into_inner());
        let order = mru.get(sid).cloned().unwrap_or_default();
        let mut out: Vec<String> = order.iter().filter(|id| live.contains(*id)).cloned().collect();
        // Any live tab the LRU never saw (defensive) goes to the back.
        for id in live {
            if !out.contains(id) {
                out.push(id.clone());
            }
        }
        out
    }
    fn mark_ephemeral(&self, sid: &str, tab_id: &str, on: bool) {
        let label = content_label(sid, tab_id);
        let mut set = self.ephemeral.lock().unwrap_or_else(|e| e.into_inner());
        if on {
            set.insert(label);
        } else {
            set.remove(&label);
        }
    }
    fn is_ephemeral(&self, sid: &str, tab_id: &str) -> bool {
        self.ephemeral.lock().unwrap_or_else(|e| e.into_inner()).contains(&content_label(sid, tab_id))
    }
    fn content_blocking(&self) -> bool {
        !self.blocking_disabled.load(Ordering::Relaxed)
    }
    fn set_content_blocking(&self, enabled: bool) {
        self.blocking_disabled.store(!enabled, Ordering::Relaxed);
    }
    // Any known surface — the default screenshot target when none is specified.
    fn any_sid(&self) -> Option<String> {
        self.surfaces.lock().unwrap_or_else(|e| e.into_inner()).keys().next().cloned()
    }
    fn set_shown(&self, sid: &str) {
        self.shown.lock().unwrap_or_else(|e| e.into_inner()).insert(sid.to_string());
    }
    fn set_hidden(&self, sid: &str) {
        self.shown.lock().unwrap_or_else(|e| e.into_inner()).remove(sid);
    }
    fn any_shown(&self) -> Option<String> {
        self.shown.lock().unwrap_or_else(|e| e.into_inner()).iter().next().cloned()
    }
    fn download_started(&self, url: &str, path: PathBuf) -> u64 {
        let mut log = self.downloads.lock().unwrap_or_else(|e| e.into_inner());
        log.next_id += 1;
        let id = log.next_id;
        log.items.push(DownloadItem {
            id,
            url: url.to_string(),
            path,
            finished: false,
        });
        id
    }
    // Resolve a Finished event (url only on macOS) to the newest unfinished
    // download of that url, marking it done.
    fn download_finished(&self, url: &str) -> Option<(u64, PathBuf)> {
        let mut log = self.downloads.lock().unwrap_or_else(|e| e.into_inner());
        let item = log
            .items
            .iter_mut()
            .rev()
            .find(|i| !i.finished && i.url == url)?;
        item.finished = true;
        Some((item.id, item.path.clone()))
    }
    fn download_path(&self, id: u64) -> Option<PathBuf> {
        let log = self.downloads.lock().unwrap_or_else(|e| e.into_inner());
        log.items.iter().find(|i| i.id == id).map(|i| i.path.clone())
    }
}

// Injected into each content webview before page scripts. Popups and
// target=_blank links open as real tabs: the shim routes the URL through a
// sentinel scheme (`bcpopup://open?u=…`) that this surface's `on_navigation`
// guard intercepts, cancels, and hands to the chrome's `__agentOpenTab` — so
// the tab strip stays in sync and the current page is never clobbered.
// Documented ceiling (roadmap Phase 1.2): `window.open` returns null, so flows
// that need a live `window.opener`/`postMessage` back-channel still fail;
// fixing those requires a real WKUIDelegate popup webview.
const POPUPS_AS_TABS_JS: &str = r#"
(function () {
  try {
    function openAsTab(url) {
      if (url) {
        try {
          var abs = new URL(String(url), window.location.href).href;
          window.location.href = "bcpopup://open?u=" + encodeURIComponent(abs);
        } catch (_e) {}
      }
      return null;
    }
    window.open = openAsTab;
    document.addEventListener("click", function (e) {
      var link = e.target && e.target.closest && e.target.closest("a[href]");
      // Cmd/Ctrl-click any link -> new tab (browser convention).
      if (link && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        openAsTab(link.href);
        return;
      }
      var a = e.target && e.target.closest && e.target.closest("a[target]");
      if (a && a.target && a.target !== "_self" && a.href) {
        e.preventDefault();
        openAsTab(a.href);
      }
    }, true);
    // Middle-click a link -> new tab.
    document.addEventListener("auxclick", function (e) {
      if (e.button !== 1) return;
      var a = e.target && e.target.closest && e.target.closest("a[href]");
      if (a && a.href) {
        e.preventDefault();
        openAsTab(a.href);
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
                let blocking = state.content_blocking();
                create_content(
                    &app, &sid, FIRST_TAB, &content_url, x, cy, width, content_h, false, blocking,
                )?;
                FIRST_TAB.to_string()
            }
        },
    };

    state.set(&sid, &show_id);
    state.set_shown(&sid);
    show_only(&app, &sid, &show_id, x, cy, width, content_h);
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
    let chrome_h = CHROME_HEIGHT.min(height);
    let content_h = (height - chrome_h).max(0.0);
    let cy = y + chrome_h;

    state.set_shown(&sid);
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
    ephemeral: Option<bool>,
) -> Result<(), String> {
    let sid = sanitize_sid(&surface_id);
    let is_ephemeral = ephemeral.unwrap_or(false);
    let (x, y, w, h) = sample_content_bounds(&app, &sid).ok_or("no content bounds yet")?;
    create_content(&app, &sid, &tab_id, &url, x, y, w, h, is_ephemeral, state.content_blocking())?;
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
                create_content(&app, &sid, &tab_id, u, x, y, w, h, false, state.content_blocking())?;
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
pub fn browser_screenshot(
    app: AppHandle,
    state: State<BrowserState>,
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

/// Extraction script for `browser_read_active`: the rendered page as the user
/// sees it — title, visible text (innerText, capped), and deduped http(s)
/// links. Returns a JSON string (WebKit hands JS strings back to the
/// completion handler as NSString).
const READ_PAGE_JS: &str = r#"
JSON.stringify((function () {
  var links = [];
  var seen = {};
  var as = document.links || [];
  for (var i = 0; i < as.length && links.length < 200; i++) {
    var a = as[i];
    var label = (a.innerText || "").replace(/\s+/g, " ").trim().slice(0, 120);
    if (!a.href || !/^https?:/i.test(a.href) || !label) continue;
    var key = label + "|" + a.href;
    if (seen[key]) continue;
    seen[key] = 1;
    links.push({label: label, url: a.href});
  }
  var text = ((document.body && document.body.innerText) || "").slice(0, 200000);
  return {url: location.href, title: document.title || "", text: text, links: links};
})())
"#;

/// The page the user is viewing, read from the **rendered DOM** of the active
/// content tab (agent co-presence). Unlike the server-side fetch pipeline,
/// this sees the page as the user's session sees it — logged-in views
/// included; the Phoenix command layer records the Sentinel event for that.
/// Returns `{data}`: a JSON string of `{url, title, text, links}`.
#[tauri::command]
pub fn browser_read_active(
    app: AppHandle,
    state: State<BrowserState>,
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

/// Interaction script for `browser_find_elements_active`: collects the page's
/// visible interactive elements, registers the live references in
/// `window.__bcEls` (the per-page index registry `browser_click_active` /
/// `browser_fill_active` act on — navigation invalidates it), and returns a
/// JSON string: an array of `{i, tag, type, label, value, href}`. `query`
/// (page-controlled once eval'd, so it arrives via `js_str`) is a
/// case-insensitive substring filter on the label.
fn find_elements_js(query: &str) -> String {
    format!(
        r#"
JSON.stringify((function () {{
  var q = {query}.toLowerCase();
  var sel = 'a[href], button, input, select, textarea, [role="button"], [onclick]';
  var nodes = document.querySelectorAll(sel);
  var els = [];
  var out = [];
  for (var i = 0; i < nodes.length && out.length < 100; i++) {{
    var el = nodes[i];
    if (el.offsetParent === null && el.getClientRects().length === 0) continue;
    var label = (el.innerText || el.placeholder || el.getAttribute("aria-label") ||
      el.getAttribute("name") || "").replace(/\s+/g, " ").trim().slice(0, 120);
    if (q && label.toLowerCase().indexOf(q) === -1) continue;
    out.push({{
      i: els.length,
      tag: el.tagName.toLowerCase(),
      type: el.getAttribute("type") || "",
      label: label,
      value: typeof el.value === "string" ? el.value.slice(0, 120) : "",
      href: typeof el.href === "string" ? el.href : ""
    }});
    els.push(el);
  }}
  window.__bcEls = els;
  return out;
}})())
"#,
        query = js_str(query)
    )
}

// Shared JS snippet: a registered element's human label (mirrors the label
// logic in find_elements_js).
const EL_LABEL_JS: &str = r#"(el.innerText || el.placeholder || el.getAttribute("aria-label") ||
    el.getAttribute("name") || "").replace(/\s+/g, " ").trim().slice(0, 120)"#;

// Look up `window.__bcEls[index]`; stale/missing entries return the "stale
// index" error the agent recovers from by re-running browser_find_elements.
fn el_lookup_js(index: usize) -> String {
    format!(
        r#"var els = window.__bcEls;
  var el = els && els[{index}];
  if (!el || !el.isConnected)
    return {{ok: false, error: "stale index — call browser_find_elements again"}};"#
    )
}

fn click_js(index: usize) -> String {
    format!(
        r#"
JSON.stringify((function () {{
  {lookup}
  var label = {label};
  if (el.focus) el.focus();
  el.click();
  return {{ok: true, label: label}};
}})())
"#,
        lookup = el_lookup_js(index),
        label = EL_LABEL_JS
    )
}

fn fill_js(index: usize, value: &str) -> String {
    format!(
        r#"
JSON.stringify((function () {{
  {lookup}
  var tag = el.tagName.toLowerCase();
  if (tag !== "input" && tag !== "textarea" && tag !== "select")
    return {{ok: false, error: "not fillable (" + tag + ")"}};
  if (el.focus) el.focus();
  el.value = {value};
  el.dispatchEvent(new Event("input", {{bubbles: true}}));
  el.dispatchEvent(new Event("change", {{bubbles: true}}));
  return {{ok: true, label: {label}}};
}})())
"#,
        lookup = el_lookup_js(index),
        value = js_str(value),
        label = EL_LABEL_JS
    )
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
pub fn browser_find_elements_active(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
    query: Option<String>,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "scanning");
    let webview = active_content(&app, &state, surface_id)?;
    let js = find_elements_js(query.as_deref().unwrap_or(""));
    let data = eval_with_result(&webview, &js)?;
    Ok(EvalData { data })
}

/// Click element `index` from the tab's `window.__bcEls` registry (agent
/// co-presence — acts inside the user's live session). Returns `{data}`: a
/// JSON string of `{ok, label}` or `{ok: false, error}`.
#[tauri::command]
pub fn browser_click_active(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
    index: usize,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "clicking");
    let webview = active_content(&app, &state, surface_id)?;
    let data = eval_with_result(&webview, &click_js(index))?;
    Ok(EvalData { data })
}

/// Fill element `index` from the tab's `window.__bcEls` registry with `value`,
/// dispatching bubbling `input` + `change` events so framework listeners
/// notice (agent co-presence — acts inside the user's live session). Returns
/// `{data}`: a JSON string of `{ok, label}` or `{ok: false, error}`.
#[tauri::command]
pub fn browser_fill_active(
    app: AppHandle,
    state: State<BrowserState>,
    surface_id: Option<String>,
    index: usize,
    value: String,
) -> Result<EvalData, String> {
    ping_agent_activity(&app, &state, surface_id.clone(), "typing");
    let webview = active_content(&app, &state, surface_id)?;
    let data = eval_with_result(&webview, &fill_js(index, &value))?;
    Ok(EvalData { data })
}

// Run JS in a webview and return its (string) result — the completion-handler
// variant of `eval`. Same objc bridge pattern as the screenshot/title paths:
// `with_webview` runs on the main thread, which is free to fire the completion
// while this (worker-thread) command blocks on the channel.
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
        .eval(&format!(
            "window.__agentOpenTab && window.__agentOpenTab({}, {ephemeral})",
            js_str(parsed.as_str())
        ))
        .map_err(|e| e.to_string())
}

// Report a finished download to Phoenix (`POST /browser/download`) so it lands
// on the Sentinel audit feed — a download pulls untrusted bytes onto disk, the
// one browser ingress the server-side fetch pipeline never sees.
fn report_download(app: &AppHandle, chrome_label: &str, url: &str, file: &PathBuf, success: bool) {
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
pub fn browser_reveal_download(
    state: State<BrowserState>,
    download_id: u64,
) -> Result<(), String> {
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
    let _ = webview.eval(&format!(
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
    main.eval(&format!("window.location.href = {}", js_str(&path)))
        .map_err(|e| e.to_string())
}

// Parse a URL and require an http(s) scheme (the content webviews refuse other
// schemes anyway; reject early with a clear message).
fn parse_web_url(url: &str) -> Result<Url, String> {
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;
    match parsed.scheme() {
        "http" | "https" => Ok(parsed),
        other => Err(format!("only http(s) URLs are allowed, got {other}")),
    }
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
        let _ = chrome.eval(&format!(
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
    let ordered = state.live_by_recency(sid, &live);
    for id in ordered.iter().skip(MAX_LIVE_TABS) {
        if id == active_id || state.is_ephemeral(sid, id) {
            continue;
        }
        if let Some(webview) = app.get_webview(&content_label(sid, id)) {
            let _ = webview.close();
            if let Some(chrome) = app.get_webview(&chrome_label(sid)) {
                let _ = chrome.eval(&format!(
                    "window.__onTabSuspended && window.__onTabSuspended({})",
                    js_str(id)
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
                        let _ = chrome.eval(&format!(
                            "window.__onDownloadStarted && window.__onDownloadStarted({id}, {})",
                            js_str(&name)
                        ));
                    }
                }
                DownloadEvent::Finished { url, success, .. } => {
                    if let Some((id, path)) = state.download_finished(url.as_str()) {
                        if let Some(chrome) = app_for_dl.get_webview(&chrome_for_dl) {
                            let _ = chrome.eval(&format!(
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
                        let _ = chrome.eval(&format!(
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
        .initialization_script(POPUPS_AS_TABS_JS);

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
        let _ = chrome.eval(&format!(
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
    let Ok(parsed) = url.parse::<Url>() else { return };
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

// Encode a string as a JS string literal for safe interpolation into eval'd JS.
// The single crate-wide encoder (main.rs's release-monitor navigation uses it
// too), so the U+2028/U+2029 escaping below is applied everywhere.
pub(crate) fn js_str(s: &str) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;

    // Parity fixtures: keep in lockstep with the sanitiser test in
    // test/buster_claw_web/controllers/browser_chrome_controller_test.exs. Both
    // sides must agree on the sanitised id or the chrome and Rust address
    // different surfaces and the browser goes blank.
    #[test]
    fn sanitize_sid_matches_the_phoenix_sanitiser() {
        let fixtures = [
            ("main", "main"),
            ("left", "left"),
            ("A1b2", "A1b2"),
            ("a\"-<b>/3", "ab3"),
            ("we-ird_id", "weirdid"),
            ("../etc", "etc"),
            ("", "main"),
            ("!!!", "main"),
        ];
        for (input, expected) in fixtures {
            assert_eq!(sanitize_sid(input), expected, "sid {input:?}");
        }
    }

    // The interaction scripts interpolate agent-supplied strings; they must
    // ride through js_str, never raw format — a hostile value/query can't
    // break out of the eval'd literal.
    #[test]
    fn interaction_scripts_escape_agent_supplied_strings() {
        let fill = fill_js(3, "a\"; alert(1); //\u{2028}");
        assert!(fill.contains(r#"el.value = "a\"; alert(1); //\u2028""#));
        assert!(fill.contains("window.__bcEls"));
        assert!(fill.contains("els[3]"));

        let find = find_elements_js("Sign\" out");
        assert!(find.contains(r#"var q = "Sign\" out".toLowerCase()"#));

        let click = click_js(7);
        assert!(click.contains("els[7]"));
        assert!(click.contains("el.click()"));
    }

    #[test]
    fn js_str_escapes_page_controlled_input() {
        assert_eq!(js_str("plain"), "\"plain\"");
        assert_eq!(js_str("a\"b"), "\"a\\\"b\"");
        assert_eq!(js_str("a\\b"), "\"a\\\\b\"");
        assert_eq!(js_str("a\nb\tc"), "\"a\\nb\\tc\"");
        // A hostile title can't break out of the eval'd literal.
        assert_eq!(
            js_str("</script>\u{2028}alert(1)"),
            "\"</script>\\u2028alert(1)\""
        );
        assert_eq!(js_str("\u{1}"), "\"\\u0001\"");
    }
}
