//! The injected-JS layer: every script string eval'd inside a content webview,
//! and `js_str`, the escaper that keeps agent- and page-controlled strings
//! inert inside those scripts. SECURITY-CRITICAL and PURE — functions here
//! build strings, the impure shell evals them; no tauri, no webviews
//! (enforced by tests/acl_lockstep.rs).

// Injected into each content webview before page scripts. Popups and
// target=_blank links open as real tabs: the shim routes the URL through a
// sentinel scheme (`bcpopup://open?u=…`) that this surface's `on_navigation`
// guard intercepts, cancels, and hands to the chrome's `__agentOpenTab` — so
// the tab strip stays in sync and the current page is never clobbered.
// Documented ceiling (roadmap Phase 1.2): `window.open` returns null, so flows
// that need a live `window.opener`/`postMessage` back-channel still fail;
// fixing those requires a real WKUIDelegate popup webview.
pub(super) const POPUPS_AS_TABS_JS: &str = r#"
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

/// Extraction script for `browser_read_active`: the rendered page as the user
/// sees it — title, visible text (innerText, capped), and deduped http(s)
/// links. Returns a JSON string (WebKit hands JS strings back to the
/// completion handler as NSString).
pub(super) const READ_PAGE_JS: &str = r#"
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

/// Interaction script for `browser_find_elements_active`: collects the page's
/// visible interactive elements, registers the live references in
/// `window.__bcEls` (the per-page index registry `browser_click_active` /
/// `browser_fill_active` act on — navigation invalidates it), and returns a
/// JSON string: an array of `{i, tag, type, label, value, href}`. `query`
/// (page-controlled once eval'd, so it arrives via `js_str`) is a
/// case-insensitive substring filter on the label.
pub(super) fn find_elements_js(query: &str) -> String {
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

/// How `browser_click_active` / `browser_fill_active` resolve the element to
/// act on, in priority order when several are given: an explicit CSS
/// selector, then visible-text matching, then the legacy `window.__bcEls`
/// index from `browser_find_elements_active`. Resolution happens at act time
/// inside the page script, which tags its result with `matched_by` so the
/// agent knows which strategy fired.
pub(crate) enum ActTarget {
    Selector(String),
    Text(String),
    Index(usize),
}

impl ActTarget {
    pub(super) fn from_params(
        index: Option<usize>,
        selector: Option<String>,
        text: Option<String>,
    ) -> Option<Self> {
        if let Some(selector) = selector {
            Some(Self::Selector(selector))
        } else if let Some(text) = text {
            Some(Self::Text(text))
        } else {
            index.map(Self::Index)
        }
    }

    // The resolution prelude: binds `el` + `matchedBy`, or returns the
    // `{ok: false}` object the Elixir side surfaces as an element_action
    // failure. Selector/text matches may sit below the fold, so those paths
    // scroll into view before acting; the index path keeps the original
    // find_elements semantics untouched — no scroll, same stale-index error.
    fn resolve_js(&self) -> String {
        match self {
            Self::Selector(selector) => format!(
                r#"var el;
  try {{ el = document.querySelector({selector}); }}
  catch (e) {{ return {{ok: false, error: "invalid selector"}}; }}
  if (!el) return {{ok: false, error: "no element matches selector"}};
  var matchedBy = "selector";
  el.scrollIntoView({{block: "center"}});"#,
                selector = js_str(selector)
            ),
            Self::Text(text) => format!(
                r#"var t = {text};
  var tl = t.toLowerCase();
  var sel = 'a[href], button, input, select, textarea, [role="button"], [onclick]';
  var nodes = document.querySelectorAll(sel);
  var el = null;
  var sub = null;
  for (var i = 0; i < nodes.length; i++) {{
    var n = nodes[i];
    if (n.offsetParent === null && n.getClientRects().length === 0) continue;
    var label = (n.innerText || n.placeholder || n.getAttribute("aria-label") ||
      n.getAttribute("name") || "").replace(/\s+/g, " ").trim();
    if (label === t) {{ el = n; break; }}
    if (!sub && label.toLowerCase().indexOf(tl) !== -1) sub = n;
  }}
  if (!el) el = sub;
  if (!el) return {{ok: false, error: "no element matches text"}};
  var matchedBy = "text";
  el.scrollIntoView({{block: "center"}});"#,
                text = js_str(text)
            ),
            Self::Index(index) => {
                format!("{}\n  var matchedBy = \"index\";", el_lookup_js(*index))
            }
        }
    }
}

pub(super) fn click_js(target: &ActTarget) -> String {
    format!(
        r#"
JSON.stringify((function () {{
  {resolve}
  var label = {label};
  if (el.focus) el.focus();
  el.click();
  return {{ok: true, label: label, matched_by: matchedBy}};
}})())
"#,
        resolve = target.resolve_js(),
        label = EL_LABEL_JS
    )
}

pub(super) fn fill_js(target: &ActTarget, value: &str) -> String {
    format!(
        r#"
JSON.stringify((function () {{
  {resolve}
  var tag = el.tagName.toLowerCase();
  if (tag !== "input" && tag !== "textarea" && tag !== "select")
    return {{ok: false, error: "not fillable (" + tag + ")"}};
  if (el.focus) el.focus();
  el.value = {value};
  el.dispatchEvent(new Event("input", {{bubbles: true}}));
  el.dispatchEvent(new Event("change", {{bubbles: true}}));
  return {{ok: true, label: {label}, matched_by: matchedBy}};
}})())
"#,
        resolve = target.resolve_js(),
        value = js_str(value),
        label = EL_LABEL_JS
    )
}

// The `{ok: false}` data payload the Elixir side decodes as a command-level
// failure — distinct from a transport-level Err. js_str's output is also a
// valid JSON string literal, so it does the quoting.
pub(super) fn error_data(msg: &str) -> String {
    format!(r#"{{"ok":false,"error":{}}}"#, js_str(msg))
}

pub(super) const NO_TARGET_DATA: &str = r#"{"ok":false,"error":"no target"}"#;

// Build the wait probe: a tiny script evaluating to "1" (condition holds),
// "0" (not yet), or "e" (the selector itself is invalid — surfaced
// immediately instead of burning the whole budget). Err = unusable
// condition/value combo, reported as `{ok: false}` data, never a transport
// error.
pub(super) fn wait_probe_js(condition: &str, value: Option<&str>) -> Result<String, String> {
    match condition {
        "navigation" => Ok(r#"document.readyState === "complete" ? "1" : "0""#.to_string()),
        "selector" => {
            let sel = value.ok_or("wait condition \"selector\" needs a value (a CSS selector)")?;
            Ok(format!(
                r#"(function () {{
  try {{ return document.querySelector({sel}) ? "1" : "0"; }}
  catch (e) {{ return "e"; }}
}})()"#,
                sel = js_str(sel)
            ))
        }
        "visible" => {
            let sel = value.ok_or("wait condition \"visible\" needs a value (a CSS selector)")?;
            Ok(format!(
                r#"(function () {{
  try {{
    var el = document.querySelector({sel});
    if (!el) return "0";
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return "0";
    var cs = window.getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden") return "0";
    return "1";
  }} catch (e) {{ return "e"; }}
}})()"#,
                sel = js_str(sel)
            ))
        }
        "text" => {
            let text =
                value.ok_or("wait condition \"text\" needs a value (the text to wait for)")?;
            Ok(format!(
                r#"(function () {{
  var body = (document.body && document.body.innerText) || "";
  return body.indexOf({text}) === -1 ? "0" : "1";
}})()"#,
                text = js_str(text)
            ))
        }
        other => Err(format!("unknown wait condition: {other}")),
    }
}

// The success payload for browser_wait_active. An exhausted budget is
// `matched: false` with `ok: true` — a wait that timed out is still a
// successful wait command; flow_runner and browser_assert depend on that.
pub(super) fn wait_result_json(matched: bool, waited_ms: u128, condition: &str) -> String {
    format!(
        r#"{{"ok":true,"matched":{matched},"waited_ms":{waited_ms},"condition":{condition}}}"#,
        condition = js_str(condition)
    )
}

/// Whole-page extraction script for `browser_extract_active` without a
/// selector: url + title + visible text — the READ_PAGE_JS shape minus links,
/// wrapped in the `{ok: true}` envelope.
pub(super) const EXTRACT_PAGE_JS: &str = r#"
JSON.stringify((function () {
  var text = ((document.body && document.body.innerText) || "").slice(0, 200000);
  return {ok: true, url: location.href, title: document.title || "", text: text};
})())
"#;

// Selector extraction: up to 50 matches as `{text, href?, value?, attr?}`.
// `attr` is an optional attribute name to read per match. Both strings are
// agent-supplied, so they ride through js_str.
pub(super) fn extract_matches_js(selector: &str, attr: Option<&str>) -> String {
    let attr_line = match attr {
        Some(attr) => format!(
            r#"var av = el.getAttribute({attr});
    if (av !== null) m.attr = String(av).slice(0, 2000);"#,
            attr = js_str(attr)
        ),
        None => String::new(),
    };
    format!(
        r#"
JSON.stringify((function () {{
  var nodes;
  try {{ nodes = document.querySelectorAll({selector}); }}
  catch (e) {{ return {{ok: false, error: "invalid selector"}}; }}
  var out = [];
  for (var i = 0; i < nodes.length && out.length < 50; i++) {{
    var el = nodes[i];
    var m = {{text: (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim().slice(0, 2000)}};
    if (typeof el.href === "string" && el.href) m.href = el.href;
    if (typeof el.value === "string" && el.value) m.value = el.value.slice(0, 2000);
    {attr_line}
    out.push(m);
  }}
  return {{ok: true, count: out.length, matches: out}};
}})())
"#,
        selector = js_str(selector)
    )
}

// Injected into each content webview before page scripts. Background-tab
// eviction (MAX_LIVE_TABS) closes the webview, so a switch-back reloads the
// saved URL at the top of the page — this shim makes that reload land where
// the user left off. Positions are debounce-saved per URL into origin-scoped
// localStorage (one LRU-capped map under a single key, so a site only ever
// sees its own origin's entries) and restored on fresh loads. Restore is
// skipped when the URL carries an anchor hash, when the site restored a
// position itself, or when the entry has aged out. Form input is not
// preserved — that would mean serializing page state we can't do safely.
pub(super) const SCROLL_RESTORE_JS: &str = r##"
(function () {
  try {
    if (window.top !== window) return;
    var KEY = "__bcScrollV1";
    var TTL_MS = 6 * 60 * 60 * 1000;
    var MAX_ENTRIES = 30;
    function read() {
      try { return JSON.parse(localStorage.getItem(KEY) || "{}") || {}; }
      catch (_e) { return {}; }
    }
    function write(m) {
      try { localStorage.setItem(KEY, JSON.stringify(m)); } catch (_e) {}
    }
    function href() { return location.href.split("#")[0]; }
    function saveNow() {
      var m = read();
      m[href()] = [window.scrollX || 0, window.scrollY || 0, Date.now()];
      var keys = Object.keys(m);
      if (keys.length > MAX_ENTRIES) {
        keys.sort(function (a, b) { return (m[a][2] || 0) - (m[b][2] || 0); });
        for (var i = 0; i < keys.length - MAX_ENTRIES; i++) delete m[keys[i]];
      }
      write(m);
    }
    var t = null;
    window.addEventListener("scroll", function () {
      if (t) clearTimeout(t);
      t = setTimeout(saveNow, 250);
    }, {passive: true});
    window.addEventListener("pagehide", saveNow);
    function restore() {
      if (location.hash) return;
      var e = read()[href()];
      if (!e || (!e[0] && !e[1])) return;
      if (Date.now() - (e[2] || 0) > TTL_MS) return;
      var tries = 0;
      (function attempt() {
        if ((window.scrollY || 0) > 8) return;
        var max = (document.documentElement.scrollHeight || 0) - window.innerHeight;
        if (max >= e[1] || tries >= 20) { window.scrollTo(e[0], e[1]); return; }
        tries++;
        setTimeout(attempt, 150);
      })();
    }
    if (document.readyState === "complete") setTimeout(restore, 80);
    else window.addEventListener("load", function () { setTimeout(restore, 80); });
  } catch (_e) {}
})();
"##;

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
