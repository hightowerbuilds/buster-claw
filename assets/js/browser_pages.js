// Behaviour for the in-app browser's own pages — home, bookmarks/pages,
// workspace and history.
//
// These four pages are served by controllers under `/browser/*` and were the
// last part of the app running on INLINE <script> blocks and inline
// `onsubmit=` handlers. That is why their scope carried no CSP: `script-src
// 'self'` would have broken every one of them, so the header was simply never
// applied there — leaving the one surface that renders remote-ish content
// outside the policy that exists to stop `window.__TAURI__` -> `terminal_*` ->
// shell.
//
// Everything here is attribute-driven, so a page opts in by rendering the right
// markup and never by carrying code. Each block no-ops when its anchor is
// absent, which is what lets one bundle serve all four pages.
//
// Loaded as a fourth esbuild entry point (config/config.exs), the same way
// chrome.js and theme.js are.

import { installClawConfirm } from "./lib/claw_confirm.js"

// --- History beacon ---------------------------------------------------------
// Record opened pages/files into the browser history. Fires during navigation,
// so it must be sendBeacon rather than fetch. Was duplicated byte-for-byte in
// browser_pages_controller and browser_workspace_controller.
document.addEventListener("click", function (e) {
  var a = e.target.closest("a[data-file]")
  if (!a) return
  try {
    navigator.sendBeacon(
      "/browser/history?url=" + encodeURIComponent(a.getAttribute("href")) +
        "&label=" + encodeURIComponent(a.getAttribute("data-label"))
    )
  } catch (_e) {}
})

// --- Confirm before a destructive POST --------------------------------------
// The history page's clear buttons carry `data-claw-confirm`, serviced by the
// shared interceptor: it blocks the click, shows the app's own modal, and
// re-dispatches only on confirm — which for a submit button means the form
// posts.
//
// They used `onsubmit="return confirm('…')"`, and that was not merely a CSP
// problem: there is no WKUIDelegate in this shell, so `window.confirm()` is a
// no-op returning FALSE. Both clear buttons have therefore been dead in the
// packaged app — `return false` cancels the submit — while working perfectly in
// a dev browser. `claw_confirm_test.exs` has guarded the rest of the app
// against exactly this since it was found; these pages were outside its reach
// because it only greps `lib/buster_claw_web/**/*.ex` for the attribute, and
// theirs was spelled `onsubmit`.
installClawConfirm()

// --- Bookmark search and tag filter (browser home) --------------------------
;(function () {
  var search = document.getElementById("search")
  var clear = document.getElementById("clear")
  var nomatch = document.getElementById("nomatch")
  if (!search || !clear || !nomatch) return

  var cards = Array.prototype.slice.call(document.querySelectorAll(".card"))
  var groups = Array.prototype.slice.call(document.querySelectorAll(".bmgroup"))
  var filters = Array.prototype.slice.call(document.querySelectorAll(".filter"))
  var activeTag = null

  function apply() {
    var q = (search.value || "").trim().toLowerCase()
    var shown = 0
    cards.forEach(function (card) {
      var hay = card.getAttribute("data-search") || ""
      var tags = (card.getAttribute("data-tags") || "").split(" ")
      var matchText = !q || hay.indexOf(q) !== -1
      var matchTag = !activeTag || tags.indexOf(activeTag) !== -1
      var show = matchText && matchTag
      card.style.display = show ? "" : "none"
      if (show) shown++
    })
    // Hide a folder group (header + grid) when none of its cards survive.
    groups.forEach(function (g) {
      var visible = Array.prototype.some.call(
        g.querySelectorAll(".card"),
        function (c) { return c.style.display !== "none" }
      )
      g.style.display = visible ? "" : "none"
    })
    nomatch.hidden = shown !== 0
    clear.hidden = !q && !activeTag
  }

  search.addEventListener("input", apply)

  filters.forEach(function (btn) {
    btn.addEventListener("click", function () {
      var tag = btn.getAttribute("data-tag")
      activeTag = activeTag === tag ? null : tag
      filters.forEach(function (b) {
        b.setAttribute("aria-pressed", b.getAttribute("data-tag") === activeTag ? "true" : "false")
      })
      apply()
    })
  })

  clear.addEventListener("click", function () {
    search.value = ""
    activeTag = null
    filters.forEach(function (b) { b.setAttribute("aria-pressed", "false") })
    apply()
  })
})()
