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

    #[test]
    fn parse_web_url_allows_only_http_https() {
        assert!(parse_web_url("https://example.com/a?b=1").is_ok());
        assert!(parse_web_url("http://127.0.0.1:4000/x").is_ok());
        assert!(parse_web_url("file:///etc/passwd").is_err());
        assert!(parse_web_url("javascript:alert(1)").is_err());
        assert!(parse_web_url("ftp://mirror.example").is_err());
        assert!(parse_web_url("not a url").is_err());
    }

    #[test]
    fn webview_labels_have_parseable_shapes() {
        assert_eq!(chrome_label("main"), "browser-chrome-main");
        assert_eq!(content_label("left", "3"), "browser-content-left-3");
    }
}
