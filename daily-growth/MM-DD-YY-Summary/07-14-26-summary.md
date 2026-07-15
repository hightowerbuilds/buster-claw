# 07-14-2026 Summary

A housecleaning day that turned up a live security hole, then closed on two
operator-reported UI bugs. The roadmap shelf got pruned to the four docs that
matter, the domain settled as **busterclaw.lol**, and closing the Shortlist's
last two code items surfaced the day's real find: **the SSRF guard never
actually checked redirects** — the fix for the theoretical DNS-rebinding gap
closed a practical one nobody knew was there. Then the End key and the SVG
viewer, both WKWebView rendering quirks rather than app logic.

## busterclaw.lol, and the Signature Feed is cut (`07397f8`)

Two operator decisions. The domain is **busterclaw.lol** (was buster.mom) —
updated across the live roadmaps, `TRADEMARK.md`, and the two code comments;
dated summaries stay as history; the bundle-ID candidate follows to
`lol.busterclaw.desktop` (still a pre-first-install one-way door). And the
**Signature Feed is cut** — not the direction, nothing was ever built. The
design record moved to the archive alongside `BROWSERBASE_ROADMAP.md`
(tombstoned 07-12, now filed). The honest consequence, written into the GTM
roadmap: the subscription stands on **BusterPhone alone**, so month-six
retention has to come from the phone being genuinely good, not an asset drip.

## SSRF: pin to the vetted IP — and the redirect hole (`f08e76f`)

Shortlist #13 was the known, accepted risk: `URLGuard` resolved a hostname at
check time, Req/Finch resolved it again at connect time, and a rebinding
nameserver could answer public then internal. The fix is resolve-once-and-pin
(`URLGuard.attach/2`): the hop's URL host is rewritten to the vetted IP and
the original hostname rides `connect_options: [hostname: ...]`, which Mint
uses for the Host header, TLS SNI, **and certificate verification** — the
"tricky TLS part" the Shortlist worried about turned out to be built into
Mint. IPv4 preferred; IPv6-only hosts pin with the transport flipped to inet6.

**The find:** writing the redirect regression test exposed that Req 0.5
consumes its request-step cursor and `redirect/1` re-enters the pipeline
without resetting it — request steps **never ran on redirect hops**. The old
"req_step re-validates every hop" claim was aspirational: any public server
the agent fetched could 302 to `http://169.254.169.254/` and be followed.
That's worse than the rebinding TOCTOU the item was about. The guard's
response step (which does run every hop) now restores the original URL before
`Location` resolution and re-arms the guard, so every hop is re-validated
*and* re-pinned from a fresh lookup. `Favicons` — which follows up to three
redirects but only ever validated the first URL — is wired through the same
attach. Regression tests cover the pin shape, dual-stack/v6-only selection,
redirect re-pinning with fresh resolution, and redirect-to-blocked refused
without contact. `docs/LOCAL_TRUST.md`: rebinding moved from accepted risk to
closed.

## The tab LRU that was already there

Shortlist #8 ("tab LRU eviction — later, not urgent") turned out to have
shipped **ten days ago**: `acac24f` (07-04, background-tab suspension —
`MAX_LIVE_TABS = 6`, MRU tracking, `enforce_tab_budget` on every activation,
dimmed chips, lazy reload on switch-back). The entry was never checked off.
Verified against `browser.rs` + `chrome.js` and marked stale rather than
rebuilt.

## CLI: the last credo exemption dies (`2adbb8b`)

`CLI.main/1`'s 23-branch `case` — the codebase's one annotated
`credo:disable-for-next-line` that was real debt rather than a lookup table —
is now a multi-clause `route/2`, one head per command shape, matched top-down
in the original order. Behavior bit-identical, exemption deleted,
`credo --strict` clean with nothing to hide. Verified live against the
running server: help, `dispatch list`, `jobs list`, `commands`,
`run runtime_status`, and the too-many-args exit path.

## The Shortlist retires (`d1657b4`)

Every item closed: 1–7 and 10–12 merged 07-02, #9 cut, #8 shipped-but-stale,
#13 and #6 done today. The one open thread — the **manual desktop walk** of
the 07-02 merges, which have still only ever been verified by compile+tests —
moved to `LEFTOVERS.md` in house format, full checklist included. New small
items go straight to Leftovers now.

The roadmap shelf, after pruning: `BUSTERPHONE_ROADMAP.md`,
`DISTRIBUTION_ROADMAP.md`, `GO_TO_MARKET_ROADMAP.md`, `LEFTOVERS.md` (five
open items), and the `NUMBER_VENDING.html` reference.

## Then two operator-reported UI bugs

Change of gears from cleanup to bug reports — both turned out to be
WKWebView/rendering quirks, not app logic.

**End key inserted a tofu box instead of moving the caret (`7394645`).** The
homepage chat: pressing End dropped a box-with-x into the textarea. macOS
WKWebView maps Home/End/PageUp/PageDown to Apple function-key codepoints in
the Private Use Area (End = U+F72B) and, instead of moving the caret, inserts
the character — which has no glyph, hence the tofu. The same leak applied to
every input in the app and the browser chrome's URL bar. New
`lib/caret_keys.js` takes the keys over on capture (End/Home to line
end/start, Cmd/Ctrl for whole-value jumps, Shift extends the selection,
PageUp/PageDown swallowed in fields) and `preventDefault`s so the webview
never inserts. Installed in both bundles; pure caret math with bun tests.
Bonus: Home/End now work app-wide, not just where the bug was noticed.

**The SVG viewer cropped drawings instead of showing them whole (`c5b1491`).**
Clicking a drawing in the viewer sidebar showed only its top-left corner. Root
cause was a *missing viewBox*, not the viewer: an SVG with `width`/`height`
but no `viewBox` has no user-space→viewport mapping, so the CSS size caps
(220px cards, 85vh modal) cropped rather than scaled. The drawing guide asks
Claude for a viewBox; nothing enforced it. New `SvgViewer.normalize/1` injects
`viewBox="0 0 W H"` from numeric root dimensions (px/quotes/unquoted/decimals
handled; `%`/`em`/existing-viewBox pass through; `stroke-width` can't
masquerade as `width`; root tag only), wired at both entry points — live
stream and transcript re-extract. The modal's `svg` also got an explicit box,
fixing the opposite failure it was hiding: viewBox-only drawings had been
rendering whole but tiny at the 300×150 replaced-element default.

## State of the tree

`mix precommit` green throughout — the count grew 988 → 994 across the day's
work (0 failures, warnings-as-errors, credo --strict with zero disables that
matter), plus the front-end bun suites. All six commits pushed to main.
