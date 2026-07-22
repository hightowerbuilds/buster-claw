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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_box_insets_below_chrome_and_right_of_sidebar() {
        // Wide surface: full 220px sidebar under the 112px chrome band.
        assert_eq!(
            content_box(0.0, 0.0, 1000.0, 800.0, false),
            (220.0, 112.0, 780.0, 688.0)
        );
        // Narrow split pane: the 35% clamp beats the 220px sidebar.
        assert_eq!(
            content_box(0.0, 0.0, 400.0, 800.0, false),
            (140.0, 112.0, 260.0, 688.0)
        );
        // Collapsed: only the 16px bumper strip, offsets preserved.
        assert_eq!(
            content_box(10.0, 20.0, 1000.0, 800.0, true),
            (26.0, 132.0, 984.0, 688.0)
        );
        // Degenerate boxes clamp to zero, never negative.
        let (_, _, w, h) = content_box(0.0, 0.0, 8.0, 50.0, false);
        assert!(w >= 0.0 && h >= 0.0);
    }
}
