//! Surface/webview naming and URL admission: the sanitised surface-id alphabet,
//! the chrome/content label scheme every module parses, and the http(s)-only
//! URL gate. Pure — no tauri, no webviews (enforced by tests/acl_lockstep.rs).

use url::Url;

pub(super) const CHROME_PREFIX: &str = "browser-chrome-"; // browser-chrome-<sid>
pub(super) const CONTENT_PREFIX: &str = "browser-content-"; // browser-content-<sid>-<tabid>
pub(super) const FIRST_TAB: &str = "1";
pub(super) const DEFAULT_SID: &str = "main";

// Restrict surface ids to a hyphen-free alphanumeric alphabet so the
// `browser-content-<sid>-<tabid>` label parses unambiguously and per-surface
// prefix filtering is exact. Mirrors the dom-id sanitiser in split_live.ex.
pub(super) fn sanitize_sid(sid: &str) -> String {
    let cleaned: String = sid.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if cleaned.is_empty() {
        DEFAULT_SID.to_string()
    } else {
        cleaned
    }
}

pub(super) fn chrome_label(sid: &str) -> String {
    format!("{CHROME_PREFIX}{sid}")
}

pub(super) fn content_label(sid: &str, tab_id: &str) -> String {
    format!("{CONTENT_PREFIX}{sid}-{tab_id}")
}

// Parse a URL and require an http(s) scheme (the content webviews refuse other
// schemes anyway; reject early with a clear message).
pub(super) fn parse_web_url(url: &str) -> Result<Url, String> {
    let parsed: Url = url.parse().map_err(|e| format!("invalid url: {e}"))?;
    match parsed.scheme() {
        "http" | "https" => Ok(parsed),
        other => Err(format!("only http(s) URLs are allowed, got {other}")),
    }
}
