//! Per-surface browser bookkeeping: active-tab pointers, shown surfaces, the
//! MRU order driving background-tab suspension, ephemeral (agent sandbox)
//! marks, the session download log, surface boxes, and sidebar state. All
//! plain mutexed maps — no tauri, no webviews (enforced by
//! tests/acl_lockstep.rs); `select_evictions` is the pure decision the
//! webview shell executes.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use super::labels::{content_label, CONTENT_PREFIX};

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
    // surface id -> the surface's last full box (x, y, w, h), written by
    // open/set_bounds. browser_set_sidebar re-derives the content inset from it
    // when the sidebar collapses/expands between bounds syncs.
    boxes: Mutex<HashMap<String, (f64, f64, f64, f64)>>,
    // Surfaces whose tab sidebar is collapsed to the bumper strip. The chrome
    // owns the preference (persisted in its localStorage) and syncs it here so
    // open/set_bounds inset the content correctly.
    sidebar_collapsed: Mutex<HashSet<String>>,
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
    pub(super) fn set(&self, sid: &str, tab_id: &str) {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(sid.to_string(), tab_id.to_string());
    }
    pub(super) fn get(&self, sid: &str) -> Option<String> {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(sid)
            .cloned()
    }
    // Drop just the active-tab pointer for a surface (its chrome + other state
    // survive). Used when the active tab is closed and no sibling remains.
    pub(super) fn unset(&self, sid: &str) {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(sid);
    }
    pub(super) fn clear(&self, sid: &str) {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(sid);
        self.shown
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(sid);
        self.mru
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(sid);
        let prefix = format!("{CONTENT_PREFIX}{sid}-");
        self.ephemeral
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|l| !l.starts_with(&prefix));
    }
    pub(super) fn clear_all(&self) {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        self.shown.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.mru.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.ephemeral
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }
    // Mark a tab most-recently-used (front of its surface's LRU list).
    pub(super) fn touch(&self, sid: &str, tab_id: &str) {
        let mut mru = self.mru.lock().unwrap_or_else(|e| e.into_inner());
        let list = mru.entry(sid.to_string()).or_default();
        list.retain(|id| id != tab_id);
        list.insert(0, tab_id.to_string());
    }
    // Drop a tab from the LRU list (its chip was closed).
    pub(super) fn forget(&self, sid: &str, tab_id: &str) {
        if let Some(list) = self
            .mru
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(sid)
        {
            list.retain(|id| id != tab_id);
        }
    }
    // Live tab ids for a surface, ordered most-recently-used first. `live` is the
    // set of tab ids that currently have a webview; MRU order drives which of them
    // to keep when the budget is exceeded.
    pub(super) fn live_by_recency(&self, sid: &str, live: &HashSet<String>) -> Vec<String> {
        let mru = self.mru.lock().unwrap_or_else(|e| e.into_inner());
        let order = mru.get(sid).cloned().unwrap_or_default();
        let mut out: Vec<String> = order
            .iter()
            .filter(|id| live.contains(*id))
            .cloned()
            .collect();
        // Any live tab the LRU never saw (defensive) goes to the back.
        for id in live {
            if !out.contains(id) {
                out.push(id.clone());
            }
        }
        out
    }
    // The eviction decision behind background-tab suspension, made pure so it
    // is testable without a webview: once `active_id` has been touched to the
    // MRU front, everything beyond the MAX_LIVE_TABS most-recently-used live
    // tabs gets evicted — except the active tab (defensive; it was just
    // touched) and ephemeral tabs, whose non-persistent store can't survive an
    // evict→reload round-trip. The webview shell just closes what this returns.
    pub(super) fn select_evictions(
        &self,
        sid: &str,
        live: &HashSet<String>,
        active_id: &str,
    ) -> Vec<String> {
        self.live_by_recency(sid, live)
            .into_iter()
            .skip(MAX_LIVE_TABS)
            .filter(|id| id != active_id && !self.is_ephemeral(sid, id))
            .collect()
    }

    pub(super) fn mark_ephemeral(&self, sid: &str, tab_id: &str, on: bool) {
        let label = content_label(sid, tab_id);
        let mut set = self.ephemeral.lock().unwrap_or_else(|e| e.into_inner());
        if on {
            set.insert(label);
        } else {
            set.remove(&label);
        }
    }
    pub(super) fn is_ephemeral(&self, sid: &str, tab_id: &str) -> bool {
        self.ephemeral
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(&content_label(sid, tab_id))
    }
    pub(super) fn content_blocking(&self) -> bool {
        !self.blocking_disabled.load(Ordering::Relaxed)
    }
    pub(super) fn set_content_blocking(&self, enabled: bool) {
        self.blocking_disabled.store(!enabled, Ordering::Relaxed);
    }
    // Any known surface — the default screenshot target when none is specified.
    pub(super) fn any_sid(&self) -> Option<String> {
        self.surfaces
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .next()
            .cloned()
    }
    pub(super) fn set_shown(&self, sid: &str) {
        self.shown
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(sid.to_string());
    }
    pub(super) fn set_hidden(&self, sid: &str) {
        self.shown
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(sid);
    }
    pub(super) fn any_shown(&self) -> Option<String> {
        self.shown
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .next()
            .cloned()
    }
    pub(super) fn set_box(&self, sid: &str, bounds: (f64, f64, f64, f64)) {
        self.boxes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(sid.to_string(), bounds);
    }
    pub(super) fn box_for(&self, sid: &str) -> Option<(f64, f64, f64, f64)> {
        self.boxes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(sid)
            .copied()
    }
    pub(super) fn set_sidebar_collapsed(&self, sid: &str, collapsed: bool) {
        let mut set = self
            .sidebar_collapsed
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if collapsed {
            set.insert(sid.to_string());
        } else {
            set.remove(sid);
        }
    }
    pub(super) fn is_sidebar_collapsed(&self, sid: &str) -> bool {
        self.sidebar_collapsed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(sid)
    }
    pub(super) fn download_started(&self, url: &str, path: PathBuf) -> u64 {
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
    pub(super) fn download_finished(&self, url: &str) -> Option<(u64, PathBuf)> {
        let mut log = self.downloads.lock().unwrap_or_else(|e| e.into_inner());
        let item = log
            .items
            .iter_mut()
            .rev()
            .find(|i| !i.finished && i.url == url)?;
        item.finished = true;
        Some((item.id, item.path.clone()))
    }
    pub(super) fn download_path(&self, id: u64) -> Option<PathBuf> {
        let log = self.downloads.lock().unwrap_or_else(|e| e.into_inner());
        log.items
            .iter()
            .find(|i| i.id == id)
            .map(|i| i.path.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- Characterization freeze (07-21, shell-rebuild Phase 0): these assert
    // OBSERVED bookkeeping behavior; an intentional behavior change must update
    // them knowingly.

    #[test]
    fn active_tab_pointer_is_per_surface() {
        let s = BrowserState::default();
        assert_eq!(s.get("main"), None);
        s.set("main", "1");
        s.set("left", "4");
        assert_eq!(s.get("main").as_deref(), Some("1"));
        assert_eq!(s.get("left").as_deref(), Some("4"));
        s.unset("main");
        assert_eq!(s.get("main"), None);
        assert_eq!(s.get("left").as_deref(), Some("4"));
    }

    #[test]
    fn touch_moves_tab_to_mru_front_without_duplicates() {
        let s = BrowserState::default();
        s.touch("main", "1");
        s.touch("main", "2");
        s.touch("main", "1"); // re-touch: back to front, no duplicate entry
        let live: HashSet<String> = ["1", "2"].iter().map(|t| t.to_string()).collect();
        assert_eq!(s.live_by_recency("main", &live), vec!["1", "2"]);
    }

    #[test]
    fn live_by_recency_filters_to_live_and_appends_unseen() {
        let s = BrowserState::default();
        s.touch("main", "3");
        s.touch("main", "2");
        s.touch("main", "1"); // MRU: 1, 2, 3
                              // "2" has no live webview: MRU order among the live survives.
        let live: HashSet<String> = ["1", "3"].iter().map(|t| t.to_string()).collect();
        assert_eq!(s.live_by_recency("main", &live), vec!["1", "3"]);
        // A live tab the LRU never saw goes to the back (defensive path).
        let live: HashSet<String> = ["3", "9"].iter().map(|t| t.to_string()).collect();
        assert_eq!(s.live_by_recency("main", &live), vec!["3", "9"]);
        // A forgotten tab that is still live re-enters via the same path.
        s.forget("main", "3");
        let live: HashSet<String> = ["1", "3"].iter().map(|t| t.to_string()).collect();
        assert_eq!(s.live_by_recency("main", &live), vec!["1", "3"]);
    }

    #[test]
    fn ephemeral_marks_are_per_tab_and_cleared_with_their_surface() {
        let s = BrowserState::default();
        s.mark_ephemeral("main", "1", true);
        s.mark_ephemeral("left", "1", true);
        assert!(s.is_ephemeral("main", "1"));
        assert!(!s.is_ephemeral("main", "2"));
        s.mark_ephemeral("main", "1", false);
        assert!(!s.is_ephemeral("main", "1"));

        // clear(sid) drops only that surface's marks (content-label prefix).
        s.mark_ephemeral("main", "1", true);
        s.clear("main");
        assert!(!s.is_ephemeral("main", "1"));
        assert!(s.is_ephemeral("left", "1"));
    }

    #[test]
    fn content_blocking_defaults_on_and_toggles() {
        let s = BrowserState::default();
        assert!(s.content_blocking());
        s.set_content_blocking(false);
        assert!(!s.content_blocking());
        s.set_content_blocking(true);
        assert!(s.content_blocking());
    }

    #[test]
    fn download_ids_are_monotonic_and_finish_resolves_newest_unfinished() {
        let s = BrowserState::default();
        let a = s.download_started("https://x/f.pdf", PathBuf::from("/tmp/f.pdf"));
        let b = s.download_started("https://x/f.pdf", PathBuf::from("/tmp/f (1).pdf"));
        assert!(b > a);
        // Finished events carry only the URL on macOS: newest unfinished wins.
        let (id, path) = s.download_finished("https://x/f.pdf").unwrap();
        assert_eq!(id, b);
        assert_eq!(path, PathBuf::from("/tmp/f (1).pdf"));
        let (id, _) = s.download_finished("https://x/f.pdf").unwrap();
        assert_eq!(id, a);
        assert_eq!(s.download_finished("https://x/f.pdf"), None);
        assert_eq!(s.download_path(a), Some(PathBuf::from("/tmp/f.pdf")));
        assert_eq!(s.download_path(999), None);
    }

    #[test]
    fn surface_boxes_shown_and_sidebar_state_roundtrip() {
        let s = BrowserState::default();
        assert_eq!(s.box_for("main"), None);
        s.set_box("main", (1.0, 2.0, 3.0, 4.0));
        assert_eq!(s.box_for("main"), Some((1.0, 2.0, 3.0, 4.0)));

        assert!(!s.is_sidebar_collapsed("main"));
        s.set_sidebar_collapsed("main", true);
        assert!(s.is_sidebar_collapsed("main"));
        s.set_sidebar_collapsed("main", false);
        assert!(!s.is_sidebar_collapsed("main"));

        assert_eq!(s.any_shown(), None);
        s.set_shown("main");
        assert_eq!(s.any_shown().as_deref(), Some("main"));
        s.set_hidden("main");
        assert_eq!(s.any_shown(), None);
    }

    // ---- select_evictions (Phase 3): the pure eviction decision behind
    // enforce_tab_budget.

    fn live(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    // Touch tabs so MRU order is last-touched-first: touch("1".."n") in order
    // leaves "n" most recent.
    fn touch_all(s: &BrowserState, sid: &str, ids: &[&str]) {
        for id in ids {
            s.touch(sid, id);
        }
    }

    #[test]
    fn select_evictions_under_budget_is_empty() {
        let s = BrowserState::default();
        touch_all(&s, "main", &["1", "2", "3", "4", "5", "6"]);
        assert!(s
            .select_evictions("main", &live(&["1", "2", "3", "4", "5", "6"]), "6")
            .is_empty());
    }

    #[test]
    fn select_evictions_drops_least_recent_beyond_budget() {
        let s = BrowserState::default();
        // "1" is least recent; 7 live tabs against a budget of 6.
        touch_all(&s, "main", &["1", "2", "3", "4", "5", "6", "7"]);
        let evict = s.select_evictions("main", &live(&["1", "2", "3", "4", "5", "6", "7"]), "7");
        assert_eq!(evict, vec!["1"]);
    }

    #[test]
    fn select_evictions_never_evicts_the_active_tab() {
        let s = BrowserState::default();
        // Active sits at the BACK of the MRU (enforce_tab_budget touches it
        // first in real flow; this is the defensive path).
        touch_all(&s, "main", &["a", "1", "2", "3", "4", "5", "6"]);
        let evict = s.select_evictions("main", &live(&["a", "1", "2", "3", "4", "5", "6"]), "a");
        assert!(evict.is_empty(), "active tab must survive: {evict:?}");
    }

    #[test]
    fn select_evictions_spares_ephemeral_tabs() {
        let s = BrowserState::default();
        touch_all(&s, "main", &["eph", "1", "2", "3", "4", "5", "6"]);
        s.mark_ephemeral("main", "eph", true);
        let evict = s.select_evictions("main", &live(&["eph", "1", "2", "3", "4", "5", "6"]), "6");
        assert!(evict.is_empty(), "ephemeral tab must survive: {evict:?}");

        // The same tab un-marked is fair game again.
        s.mark_ephemeral("main", "eph", false);
        let evict = s.select_evictions("main", &live(&["eph", "1", "2", "3", "4", "5", "6"]), "6");
        assert_eq!(evict, vec!["eph"]);
    }

    #[test]
    fn select_evictions_is_per_surface() {
        let s = BrowserState::default();
        touch_all(&s, "main", &["1", "2", "3", "4", "5", "6", "7"]);
        // The other surface's MRU is empty: its live tabs all land via the
        // defensive tail, and only those beyond the budget are candidates.
        assert_eq!(
            s.select_evictions("left", &live(&["x"]), "x"),
            Vec::<String>::new()
        );
        assert_eq!(
            s.select_evictions("main", &live(&["1", "2", "3", "4", "5", "6", "7"]), "7"),
            vec!["1"]
        );
    }
}
