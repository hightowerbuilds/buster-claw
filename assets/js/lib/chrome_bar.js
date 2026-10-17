// The bookmark row under the browser toolbar — one strip, three things it can
// be showing. Bookmarks by default; omnibox suggestions while the address bar
// is being typed into; the find bar after ⌘F. The chrome's top block is a
// fixed 112px band with the content webview covering everything under it, so
// none of the three can be a dropdown or a floating panel: they take turns on
// the one row instead.
//
// Extracted from chrome.js on 10-16 (CODE_QUALITY_SWEEP Phase 8). The cap note
// that froze that file called this "three UIs sharing one bar coordinating
// through flags"; the flags (`suggestions.length`, `findOpen`) are now the one
// `mode` below, and the rule that decides what the row shows is in one place
// (`draw`). The chrome keeps the address bar, the tabs and the Tauri bridge
// and hands them in; this module never reads the tab model directly.
//
// `deps`: {barEl, addr, inv, activeId(), display(url), origin}
export function createBar(deps) {
  const {barEl, addr, inv, activeId, display, origin} = deps
  let mode = "bookmarks" // "bookmarks" | "suggestions" | "find"
  let bookmarks = []
  let suggestions = []
  let suggestIndex = -1
  let suggestTimer
  let suggestSeq = 0
  let findInput = null
  let findCount = null
  let findCountT = null

  // What the row shows is decided here and nowhere else.
  function draw() {
    if (mode === "find") return drawFindBar()
    if (mode === "suggestions" && suggestions.length) return drawSuggestions()
    mode = "bookmarks"
    drawBookmarks()
  }

  // --- bookmarks ---
  function setBookmarks(items) {
    bookmarks = items || []
    if (mode === "bookmarks") drawBookmarks()
  }

  function drawBookmarks() {
    barEl.textContent = ""
    if (!bookmarks.length) {
      const hint = document.createElement("span")
      hint.className = "hint"
      hint.textContent = "Bookmarks you save appear here"
      barEl.appendChild(hint)
      return
    }
    bookmarks.forEach((b) => {
      const el = document.createElement("button")
      el.type = "button"
      el.className = "bmk"
      el.title = (b.folder ? b.folder + " / " : "") + (b.label || b.url) + "\n" + b.url
      if (b.favicon_url) {
        const img = document.createElement("img")
        img.src = b.favicon_url; img.alt = ""; img.loading = "lazy"
        el.appendChild(img)
      }
      const t = document.createElement("span")
      t.className = "t"
      t.textContent = b.label || b.url
      el.appendChild(t)
      el.onclick = () => inv("browser_navigate", {tabId: activeId(), url: b.url})
      barEl.appendChild(el)
    })
  }

  function loadBookmarks() {
    fetch(origin + "/browser/bookmarks", {headers: {accept: "application/json"}})
      .then((r) => r.json())
      .then(setBookmarks)
      .catch(function () {})
  }

  // --- omnibox suggestions (roadmap Phase 2.2) ---
  // ↓/↑ (or Tab/⇧Tab) select, Enter opens, Esc restores the bookmarks. Fed by
  // /browser/suggest: bookmark matches + FTS history.
  function drawSuggestions() {
    barEl.textContent = ""
    suggestions.forEach((s, i) => {
      const el = document.createElement("button")
      el.type = "button"
      el.className = "sug" + (i === suggestIndex ? " sel" : "")
      el.title = s.url
      const mark = document.createElement("span")
      mark.className = "k"
      mark.textContent = s.type === "bookmark" ? "★" : "⏱"
      el.appendChild(mark)
      const t = document.createElement("span")
      t.className = "t"
      t.textContent = s.label || s.url
      el.appendChild(t)
      // mousedown (not click) so the address bar's blur can't cancel the pick.
      el.onmousedown = (e) => { e.preventDefault(); openSuggestion(s) }
      barEl.appendChild(el)
    })
  }

  function clearSuggestions() {
    clearTimeout(suggestTimer)
    suggestions = []
    suggestIndex = -1
    if (mode === "suggestions") mode = "bookmarks"
    draw()
  }

  function openSuggestion(s) {
    addr.value = display(s.url)
    clearSuggestions()
    inv("browser_navigate", {tabId: activeId(), url: s.url})
  }

  function requestSuggestions(q) {
    const seq = ++suggestSeq
    fetch(origin + "/browser/suggest?q=" + encodeURIComponent(q), {
      headers: {accept: "application/json"}
    })
      .then((r) => r.json())
      .then((items) => {
        if (seq !== suggestSeq) return // a newer keystroke owns the bar
        if (mode === "find") return // ⌘F while a request was in flight
        suggestions = Array.isArray(items) ? items : []
        suggestIndex = -1
        mode = suggestions.length ? "suggestions" : "bookmarks"
        draw()
      })
      .catch(function () {})
  }

  // The suggestion Enter would open, if a chip is selected.
  function selectedSuggestion() {
    return suggestIndex >= 0 ? suggestions[suggestIndex] || null : null
  }

  addr.addEventListener("input", function () {
    const v = addr.value.trim()
    clearTimeout(suggestTimer)
    // "/" is the workspace-browse prefix (the chrome has its own listener).
    if (v.length < 2 || v.startsWith("/")) { clearSuggestions(); return }
    suggestTimer = setTimeout(function () { requestSuggestions(v) }, 150)
  })

  addr.addEventListener("keydown", function (e) {
    if (mode !== "suggestions" || !suggestions.length) return
    const step = suggestionStep(e.key, e.shiftKey)
    if (step === 0) return
    e.preventDefault()
    if (step === "close") return clearSuggestions()
    suggestIndex = (suggestIndex + step + suggestions.length) % suggestions.length
    drawSuggestions()
  })

  addr.addEventListener("blur", function () { setTimeout(clearSuggestions, 150) })

  // --- find in page (⌘F; roadmap Phase 2.4) ---
  // Enter steps forward, ⇧Enter back, Esc closes. Matching runs in the content
  // webview via browser_find (WebKit window.find): selection + scroll with
  // wraparound.
  function openFindBar() {
    mode = "find"
    draw()
    if (findInput) { findInput.focus(); findInput.select() }
  }

  function closeFindBar() {
    mode = "bookmarks"
    findInput = null
    findCount = null
    if (findCountT) { clearTimeout(findCountT); findCountT = null }
    draw()
  }

  function findStep(backwards) {
    const q = findInput && findInput.value.trim()
    if (q) inv("browser_find", {tabId: activeId(), query: q, backwards: !!backwards})
  }

  // Total-match label ("17 matches") next to the input, refreshed when the
  // query changes (not on next/prev steps — the total doesn't move). Debounced
  // so fast typing doesn't queue a count round-trip per keystroke; a stale
  // reply (the query changed while it was in flight) is dropped.
  function updateFindCount() {
    if (findCountT) clearTimeout(findCountT)
    findCountT = setTimeout(() => {
      const q = findInput && findInput.value.trim()
      if (!findCount) return
      if (!q) { findCount.textContent = ""; findCount.classList.remove("none"); return }
      inv("browser_find_count", {tabId: activeId(), query: q}).then((n) => {
        if (!findCount || !findInput || findInput.value.trim() !== q) return
        if (typeof n !== "number") { findCount.textContent = ""; return }
        findCount.textContent = n === 0 ? "No matches" : n === 1 ? "1 match" : n + " matches"
        findCount.classList.toggle("none", n === 0)
      }).catch(() => { if (findCount) findCount.textContent = "" })
    }, 150)
  }

  function drawFindBar() {
    barEl.textContent = ""
    const wrap = document.createElement("div")
    wrap.className = "findbar"
    findInput = document.createElement("input")
    findInput.id = "find"
    findInput.type = "text"
    findInput.placeholder = "Find in page…"
    findInput.autocomplete = "off"
    findInput.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); findStep(e.shiftKey) }
      else if (e.key === "Escape") { e.preventDefault(); closeFindBar() }
    })
    findInput.addEventListener("input", function () { findStep(false); updateFindCount() })
    const mk = (label, title, fn) => {
      const b = document.createElement("button")
      b.type = "button"; b.className = "fbtn"; b.title = title; b.textContent = label
      b.onclick = fn
      return b
    }
    wrap.appendChild(findInput)
    findCount = document.createElement("span")
    findCount.className = "fcount"
    wrap.appendChild(findCount)
    wrap.appendChild(mk("‹", "Previous match (⇧↵)", () => findStep(true)))
    wrap.appendChild(mk("›", "Next match (↵)", () => findStep(false)))
    wrap.appendChild(mk("×", "Close (Esc)", closeFindBar))
    barEl.appendChild(wrap)
  }

  return {
    loadBookmarks,
    openFindBar,
    clearSuggestions,
    selectedSuggestion,
    openSuggestion,
    mode: () => mode,
  }
}

// What a key does to the suggestion chips: +1/-1 moves the selection, "close"
// restores the bookmarks, 0 means the key is not ours. Pure, so the chord
// table is tested rather than clicked.
export function suggestionStep(key, shift) {
  if (key === "ArrowDown" || (key === "Tab" && !shift)) return 1
  if (key === "ArrowUp" || (key === "Tab" && shift)) return -1
  if (key === "Escape") return "close"
  return 0
}
