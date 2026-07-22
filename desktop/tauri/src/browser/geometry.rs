//! Surface geometry: how a browser surface's box splits into the chrome bands
//! and the content inset. Pure math — no tauri, no webviews (enforced by
//! tests/acl_lockstep.rs).

// The chrome webview covers the surface's ENTIRE box; the content webview is
// created after it (NSView sibling order = paint order, so content sits on top)
// and is inset below the chrome's top block and right of its tab sidebar. The
// chrome HTML paints only those two bands — its center is permanently covered.
// CHROME_TOP_HEIGHT = app-tab row (~34) + toolbar (46) + bookmark bar (32).
const CHROME_TOP_HEIGHT: f64 = 112.0;
// The vertical browser-tab strip on the left. Narrow surfaces (split panes)
// scale it down via SIDEBAR_MAX_FRACTION; both MUST match the chrome CSS
// `--sidebar-w: min(220px, 35vw)` or the content webview will misalign.
const SIDEBAR_WIDTH: f64 = 220.0;
const SIDEBAR_MAX_FRACTION: f64 = 0.35;
// Collapsed sidebar: only the bumper strip stays. MUST match the chrome CSS
// `body.sidebar-collapsed { --sidebar-w: 16px }`.
const SIDEBAR_COLLAPSED_WIDTH: f64 = 16.0;

// Content inset for a surface box: (content_x, content_y, content_w, content_h).
pub(super) fn content_box(
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    collapsed: bool,
) -> (f64, f64, f64, f64) {
    let top_h = CHROME_TOP_HEIGHT.min(height);
    let sidebar_w = if collapsed {
        SIDEBAR_COLLAPSED_WIDTH.min(width)
    } else {
        SIDEBAR_WIDTH.min(width * SIDEBAR_MAX_FRACTION)
    };
    (
        x + sidebar_w,
        y + top_h,
        (width - sidebar_w).max(0.0),
        (height - top_h).max(0.0),
    )
}
