//! Agent co-presence: the commands that read and drive the tab the user is
//! viewing, plus the off-screen render fallback. Every one of them pings
//! `__agentActivity` first so the chrome's hazard badge shows when the agent
//! has its hands on the live page.
//!
//! Split out of mod.rs on 10-16 (CODE_QUALITY_SWEEP Phase 8): the chrome's
//! tab-lifecycle commands stay there; these are the ones the Phoenix `Browser`
//! context calls on the agent's behalf. The return structs' field names are a
//! cross-language contract (web.ex decodes them) and are pinned by the test at
//! the bottom.

use std::sync::atomic::{AtomicU64, Ordering};
use tauri::webview::WebviewBuilder;
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, State, WebviewUrl};

use super::ffi::{capture_webview, eval_with_result, webview_title};
use super::js::{
    click_js, error_data, extract_matches_js, fill_js, find_elements_js, js_str, wait_probe_js,
    wait_result_json, ActTarget, EXTRACT_PAGE_JS, NO_TARGET_DATA, READ_PAGE_JS,
};
use super::labels::{chrome_label, parse_web_url};
use super::notify::ping_agent_activity;
use super::webviews::render_settle_and_read;
use super::{active_content, active_sid, BrowserState};

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
