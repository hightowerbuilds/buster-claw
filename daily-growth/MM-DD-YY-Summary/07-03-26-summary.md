# 07-03-2026 Summary

Turned the lens on the **embedded browser**: a critical review against the field,
a code-quality audit of the browser stack, and a five-phase build-out roadmap.
Docs live in `daily-growth/roadmaps/` (`BROWSER_REVIEW.md`, `BROWSER_ROADMAP.md`);
`Shortlist.md` retired to `roadmaps/oldmaps/`.

## Browser review (new doc)

Full read of the stack — `browser.rs` (webview orchestration), the chrome page,
home page, `BrowseLive`, history/bookmarks contexts, co-presence commands —
scored against Safari/Firefox/Arc and the AI cohort (Dia, Comet, Atlas). Verdict:
**ahead of everyone as an agent co-presence surface, but a user hits something
broken within five minutes of using it as a browser.** Tier-1 breakage: the
omnibox can't search (schemeless input becomes an invalid `https://` URL),
`window.open` is stubbed to same-tab so OAuth popups break, downloads silently
no-op, and there are zero keyboard shortcuts (architectural — focus lives in the
content webview). Structural ceilings named honestly: WKWebView means no
extensions ever; one shared cookie jar across all tabs *and* split panes; a live
WKWebView per tab forever. One own-goal: favicons via `google.com/s2` leak every
visited host to Google — from the local-first, Sentinel-audited app. Strategic
frame for everything after: **never be the reason the user alt-tabs to Chrome**,
because every alt-tab removes the agent's eyes from the page.

## Code QX review (appended to the review)

Grep-verified every public function for production callers. Findings:
`BusterClaw.Browser.Reader` (117 lines + test) is fully orphaned pre-rewrite
reader-mode code — delete. ~60% of `BrowserHistory`'s API (`search`,
`grouped_by_day`, `visit_count(s)`, `clear`, `clear_range`, `list`) has test-only
callers: a shipped backend whose UI/agent commands were never built. Rust side
clean (all 15 commands registered + invoked). Modularity: macro-architecture is
crisp (Rust owns webviews, chrome JS owns the strip, Elixir owns durable state),
but the chrome is a ~330-line JS app inside an Elixir string literal, tab state
has three partial owners and none durable (why session restore is impossible),
cross-boundary logic is triplicated with only "mirrors X" comments guarding
drift, and history records on the wrong seam (chrome JS, active-tab-only). Test
coverage clusters where testing is easy (Elixir), not where the risk is — the
Rust/JS layers holding all four Tier-1 bugs have zero tests.

## Build-out roadmap (new doc)

Five phases with exit criteria and S/M/L effort tags. **Phase 0** foundations:
extract the chrome JS to real testable assets, delete Reader, de-dupe the
triplicated logic, move history recording to Rust's `on_page_load`. **Phase 1**
stop the bleeding: omnibox search, popups→tabs (WKUIDelegate for real OAuth
support), WKDownloadDelegate downloads with Sentinel audit events, native-menu
shortcuts, local favicon cache replacing the Google leak. **Phase 2** table
stakes: durable tab state + session restore (also the QX three-owners fix),
omnibox suggestions + history page (wires the dead backend), find-in-page, zoom.
**Phase 3** extend the moat: `browser_read` (authed rendered DOM), audited
click/fill verbs, agent sandbox tabs on ephemeral data stores. **Phase 4**
stretch: content blocking via `WKContentRuleList` (Safari's blocker engine, free
*because* we chose WKWebView), private mode, tab suspension. Non-goals stated:
extensions, sync, cross-platform parity, engine swap.

## Next

Phase 0 starts immediately after this commit.
