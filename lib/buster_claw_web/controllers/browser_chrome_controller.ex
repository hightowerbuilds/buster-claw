defmodule BusterClawWeb.BrowserChromeController do
  @moduledoc """
  The embedded browser's native chrome — a **tab strip** + a toolbar (back/forward/
  reload + address bar + bookmark), loaded into a `browser-chrome-<sid>` child
  webview. Served from the Phoenix origin so it can call the `browser_*` Tauri
  commands (granted via the `browser-chrome` capability, whose `browser-chrome-*`
  glob covers every surface). It owns the tab-strip UI and tab lifecycle; Rust
  owns the per-tab content webviews and the per-surface active-tab pointer.

  `?sid=` identifies the browser surface this chrome drives (`main` for the solo
  `/browse`, `left`/`right` for a browser+browser split); every `browser_*` invoke
  carries it so two side-by-side browsers stay independent.
  """
  use BusterClawWeb, :controller

  def show(conn, params) do
    initial = params["url"] || ""
    sid = sanitize_sid(params["sid"])

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(initial, sid))
  end

  # Surface ids are alphanumeric only (matches the Rust sanitiser); default "main".
  defp sanitize_sid(sid) do
    case sid |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "") do
      "" -> "main"
      cleaned -> cleaned
    end
  end

  defp page(initial, sid) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Browser chrome</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; overflow: hidden; }
      body {
        position: relative;
        display: flex; flex-direction: column; height: 112px;
        background: #121212; color: #f4f1ea;
        font: 13px/1 -apple-system, system-ui, sans-serif;
        border-bottom: 2px solid rgba(244,241,234,.18);
      }
      /* loading affordance: indeterminate hazard-orange bar across the top, shown
         while the active tab is loading. Overlaid (absolute) so it adds no layout
         height — the chrome webview stays exactly 112px tall. */
      #progress { position: absolute; top: 0; left: 0; right: 0; height: 2px;
                  overflow: hidden; pointer-events: none; opacity: 0;
                  transition: opacity .15s; z-index: 5; }
      #progress.on { opacity: 1; }
      #progress::after { content: ""; display: block; height: 100%; width: 35%;
                         background: #ff4d1c; }
      #progress.on::after { animation: ic-load 1s ease-in-out infinite; }
      @keyframes ic-load { 0% { margin-left: -35%; } 100% { margin-left: 100%; } }
      @keyframes ic-spin { to { transform: rotate(360deg); } }
      /* tab strip */
      #tabs { display: flex; align-items: stretch; gap: 4px; height: 34px;
              padding: 4px 6px 0; overflow-x: auto; overflow-y: hidden; }
      #tabs::-webkit-scrollbar { height: 0; }
      .tab { display: flex; align-items: center; gap: 6px; max-width: 200px;
             padding: 0 8px; height: 30px; cursor: pointer; flex: 0 0 auto;
             background: #1c1c1c; color: rgba(244,241,234,.6);
             border: 1px solid rgba(244,241,234,.14); border-bottom: none;
             border-radius: 6px 6px 0 0; }
      .tab.active { background: #2a2a2a; color: #f4f1ea; border-color: rgba(244,241,234,.3); }
      .tab .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
                    font-size: 12px; max-width: 150px; }
      .tab .fav { width: 14px; height: 14px; flex: 0 0 auto; border-radius: 3px; }
      .tab .spin { width: 12px; height: 12px; flex: 0 0 auto; border-radius: 50%;
                   border: 2px solid rgba(244,241,234,.25); border-top-color: #ff4d1c;
                   animation: ic-spin .7s linear infinite; }
      .tab .x { display: grid; place-items: center; width: 16px; height: 16px;
                border-radius: 3px; color: rgba(244,241,234,.45); font-size: 13px;
                flex: 0 0 auto; }
      .tab .x:hover { background: rgba(244,241,234,.12); color: #ff4d1c; }
      #newtab { flex: 0 0 auto; width: 28px; height: 30px; display: grid;
                place-items: center; background: transparent; color: #f4f1ea;
                border: 1px solid rgba(244,241,234,.2); border-radius: 6px 6px 0 0;
                cursor: pointer; font-size: 16px; line-height: 1; }
      #newtab:hover { border-color: #ff4d1c; color: #ff4d1c; }
      /* toolbar */
      #toolbar { display: flex; align-items: center; gap: 6px; padding: 0 8px;
                 height: 46px; }
      button.nav {
        flex: 0 0 auto; width: 30px; height: 30px; display: grid; place-items: center;
        background: transparent; color: #f4f1ea; border: 2px solid rgba(244,241,234,.2);
        border-radius: 3px; cursor: pointer; font-size: 14px; line-height: 1;
      }
      button.nav:hover { border-color: #ff4d1c; color: #ff4d1c; }
      form { flex: 1 1 auto; display: flex; gap: 6px; min-width: 0; }
      input {
        flex: 1 1 auto; min-width: 0; height: 30px; padding: 0 10px;
        background: #1c1c1c; color: #f4f1ea; border: 2px solid rgba(244,241,234,.2);
        border-radius: 3px; font: 12px/1 ui-monospace, monospace; outline: none;
      }
      input:focus { border-color: rgba(244,241,234,.45); }
      button.go {
        flex: 0 0 auto; height: 30px; padding: 0 14px; cursor: pointer;
        background: #ff4d1c; color: #121212; border: 0; border-radius: 3px;
        font-weight: 700; font-size: 12px;
      }
      button.bm {
        flex: 0 0 auto; height: 30px; padding: 0 12px; cursor: pointer;
        background: transparent; color: #f4f1ea; border: 2px solid rgba(244,241,234,.2);
        border-radius: 3px; font: 600 12px/1 ui-monospace, monospace; white-space: nowrap;
      }
      button.bm:hover { border-color: #ff4d1c; color: #ff4d1c; }
      /* bookmark bar */
      #bookmarkbar { display: flex; align-items: center; gap: 4px; height: 32px;
                     padding: 0 8px; overflow-x: auto; overflow-y: hidden;
                     border-top: 1px solid rgba(244,241,234,.1); }
      #bookmarkbar::-webkit-scrollbar { height: 0; }
      .bmk { display: flex; align-items: center; gap: 6px; flex: 0 0 auto; max-width: 160px;
             height: 24px; padding: 0 8px; cursor: pointer; background: transparent;
             color: rgba(244,241,234,.75); border: 1px solid transparent; border-radius: 4px;
             font: 12px/1 -apple-system, system-ui, sans-serif; }
      .bmk:hover { background: rgba(244,241,234,.08); color: #f4f1ea;
                   border-color: rgba(244,241,234,.14); }
      .bmk img { width: 14px; height: 14px; flex: 0 0 auto; border-radius: 3px; }
      .bmk .t { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      #bookmarkbar .hint { color: rgba(244,241,234,.32); font-size: 11px; padding: 0 4px;
                           white-space: nowrap; }
    </style>
    </head>
    <body>
      <div id="progress"></div>
      <div id="tabs"></div>
      <div id="toolbar">
        <button class="nav" id="home" title="Home" aria-label="Home">&#8962;</button>
        <button class="nav" id="back" title="Back" aria-label="Back">&#9664;</button>
        <button class="nav" id="fwd" title="Forward" aria-label="Forward">&#9654;</button>
        <button class="nav" id="reload" title="Reload" aria-label="Reload">&#8635;</button>
        <form id="form">
          <input id="addr" type="text" autocomplete="off" spellcheck="false"
                 placeholder="https://… or /path in your workspace"
                 value="#{escape_attr(initial)}" />
          <button class="go" type="submit">Go</button>
        </form>
        <button class="bm" id="bookmark" type="button" title="Bookmark this page">+ Bookmark</button>
      </div>
      <div id="bookmarkbar"></div>
      <script>
        const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke
        const origin = window.location.origin
        const homeUrl = origin + "/browser/home"
        // The browser surface this chrome drives. Every browser_* invoke carries
        // it (injected by inv() below) so side-by-side browsers stay independent.
        const SID = "#{sid}"
        const addr = document.getElementById("addr")
        const tabsEl = document.getElementById("tabs")
        const barEl = document.getElementById("bookmarkbar")
        const progressEl = document.getElementById("progress")

        // Invoke a Tauri command, surfacing failures in the console (so a denied
        // permission or a missing webview is visible rather than silent). Every
        // browser_* command is surface-scoped, so inject surfaceId here.
        function inv(cmd, args) {
          if (!invoke) return Promise.resolve()
          return invoke(cmd, Object.assign({ surfaceId: SID }, args || {})).catch(function (e) {
            console.error("browser " + cmd + " failed:", e)
          })
        }

        // --- tab state (chrome owns the strip; Rust owns the webviews) ---
        // Each tab also tracks `loading` (spinner while a navigation is in flight)
        // and `favicon` (host favicon, mirroring the bookmark-bar pattern).
        let tabs = [{ id: "1", url: "", label: "New tab", loading: false, favicon: null }]
        let activeId = "1"
        let nextId = 2

        function resolve(raw) {
          const v = (raw || "").trim()
          if (v === "") return null
          if (/^[a-z]+:\\/\\//i.test(v)) return v
          if (v.startsWith("/")) return origin + "/ws/file?path=" + encodeURIComponent(v)
          return "https://" + v
        }
        // Friendly address for the bar.
        function display(u) {
          try {
            const url = new URL(u, origin)
            if (url.origin === origin) {
              if (url.pathname === "/browser/home") return ""
              if (url.pathname === "/ws/file") return url.searchParams.get("path") || u
              if (url.pathname === "/browser/workspace") return url.searchParams.get("q") || "/"
            }
            return u
          } catch (e) { return u }
        }
        // Short label for a tab.
        function deriveLabel(u) {
          if (!u || u === homeUrl) return "New tab"
          try {
            const url = new URL(u, origin)
            if (url.origin === origin) {
              if (url.pathname === "/browser/home") return "New tab"
              if (url.pathname === "/ws/file") {
                const p = url.searchParams.get("path") || "/"
                return p.split("/").filter(Boolean).pop() || "Workspace"
              }
              if (url.pathname === "/browser/workspace") return "Workspace"
            }
            return url.hostname.replace(/^www\\./, "") || u
          } catch (e) { return u }
        }
        // Host favicon for a tab, matching the bookmark bar's Google s2 pattern
        // (BusterClaw.Bookmarks.favicon_url/1). Only for real http(s) hosts —
        // workspace/home pages on our own origin get no favicon.
        function faviconFor(u) {
          try {
            const url = new URL(u, origin)
            if (url.origin === origin) return null
            if (url.protocol !== "http:" && url.protocol !== "https:") return null
            if (!url.hostname) return null
            return "https://www.google.com/s2/favicons?domain=" +
                   encodeURIComponent(url.hostname) + "&sz=64"
          } catch (e) { return null }
        }

        // Reflect the active tab's loading state in the top progress bar.
        function updateProgress() {
          const t = activeTab()
          progressEl.classList.toggle("on", !!(t && t.loading))
        }

        function renderTabs() {
          tabsEl.textContent = ""
          tabs.forEach((t) => {
            const tab = document.createElement("div")
            tab.className = "tab" + (t.id === activeId ? " active" : "")
            tab.title = t.label
            // Leading affordance: a spinner while loading, otherwise the favicon.
            if (t.loading) {
              const spin = document.createElement("span")
              spin.className = "spin"
              tab.appendChild(spin)
            } else if (t.favicon) {
              const fav = document.createElement("img")
              fav.className = "fav"
              fav.src = t.favicon; fav.alt = ""; fav.loading = "lazy"
              fav.onerror = () => fav.remove()
              tab.appendChild(fav)
            }
            const label = document.createElement("span")
            label.className = "label"
            label.textContent = t.label
            label.onclick = () => switchTab(t.id)
            const x = document.createElement("span")
            x.className = "x"
            x.textContent = "\\u00d7"
            x.title = "Close tab"
            x.onclick = (e) => { e.stopPropagation(); closeTab(t.id) }
            tab.appendChild(label)
            tab.appendChild(x)
            tabsEl.appendChild(tab)
          })
          const add = document.createElement("button")
          add.id = "newtab"; add.type = "button"; add.title = "New tab"; add.textContent = "+"
          add.onclick = () => newTab()
          tabsEl.appendChild(add)
          updateProgress()
        }

        function activeTab() { return tabs.find((t) => t.id === activeId) }

        // --- bookmark bar (persistent quick-access strip below the toolbar) ---
        function renderBookmarks(items) {
          barEl.textContent = ""
          if (!items || !items.length) {
            const hint = document.createElement("span")
            hint.className = "hint"
            hint.textContent = "Bookmarks you save appear here"
            barEl.appendChild(hint)
            return
          }
          items.forEach((b) => {
            const el = document.createElement("button")
            el.type = "button"
            el.className = "bmk"
            el.title = (b.folder ? b.folder + " / " : "") + (b.label || b.url) + "\\n" + b.url
            if (b.favicon_url) {
              const img = document.createElement("img")
              img.src = b.favicon_url; img.alt = ""; img.loading = "lazy"
              el.appendChild(img)
            }
            const t = document.createElement("span")
            t.className = "t"
            t.textContent = b.label || b.url
            el.appendChild(t)
            el.onclick = () => inv("browser_navigate", { tabId: activeId, url: b.url })
            barEl.appendChild(el)
          })
        }
        function loadBookmarks() {
          fetch(origin + "/browser/bookmarks", { headers: { accept: "application/json" } })
            .then((r) => r.json())
            .then(renderBookmarks)
            .catch(function () {})
        }

        function newTab() {
          const id = String(nextId++)
          tabs.push({ id, url: "", label: "New tab", loading: false, favicon: null })
          activeId = id
          addr.value = ""
          renderTabs()
          inv("browser_new_tab", { tabId: id, url: homeUrl })
          addr.focus()
        }

        function switchTab(id) {
          if (id === activeId) return
          activeId = id
          const t = activeTab()
          if (t && document.activeElement !== addr) addr.value = display(t.url)
          renderTabs()
          inv("browser_switch_tab", { tabId: id })
        }

        function closeTab(id) {
          inv("browser_close_tab", { tabId: id })
          const i = tabs.findIndex((t) => t.id === id)
          if (i < 0) return
          tabs.splice(i, 1)
          if (!tabs.length) { renderTabs(); newTab(); return }
          if (activeId === id) {
            const next = tabs[Math.max(0, i - 1)]
            activeId = next.id
            addr.value = display(next.url)
            inv("browser_switch_tab", { tabId: next.id })
          }
          renderTabs()
        }

        // Called from Rust when a tab *starts* navigating (before the page loads):
        // show the spinner and update the address bar/url optimistically. The real
        // title arrives on completion via __onContentNavigated below.
        window.__onContentLoading = function (id, u) {
          const t = tabs.find((x) => x.id === id)
          if (t) {
            t.url = u
            t.loading = true
            t.favicon = faviconFor(u)
            t.label = deriveLabel(u)
            // Safety net: some loads never report completion — network errors,
            // downloads, and blocked navigations don't fire on_page_load Finished,
            // so __onContentNavigated never clears the spinner. Drop it after a
            // grace period so it can't spin forever.
            clearTimeout(t.loadTimer)
            t.loadTimer = setTimeout(function () {
              const cur = tabs.find((x) => x.id === id)
              if (cur && cur.loading) { cur.loading = false; renderTabs() }
            }, 20000)
          }
          if (id === activeId && document.activeElement !== addr) addr.value = display(u)
          // New page → reset the bookmark button so a fresh save reads clearly.
          if (id === activeId) {
            const bm = document.getElementById("bookmark")
            if (bm) bm.textContent = "+ Bookmark"
          }
          renderTabs()
        }

        // Called from Rust when a tab finishes loading, per tab id. `title` is the
        // page's document.title (empty when unavailable); `favicon` is optional and
        // falls back to a host-derived icon.
        window.__onContentNavigated = function (id, u, title, favicon) {
          const t = tabs.find((x) => x.id === id)
          if (t) {
            clearTimeout(t.loadTimer)
            t.url = u
            t.loading = false
            t.favicon = favicon || faviconFor(u)
            const named = (title || "").trim()
            t.label = named || deriveLabel(u)
          }
          if (id === activeId && document.activeElement !== addr) addr.value = display(u)
          // New page → reset the bookmark button so a fresh save reads clearly.
          if (id === activeId) {
            const bm = document.getElementById("bookmark")
            if (bm) bm.textContent = "+ Bookmark"
          }
          renderTabs()
          if (id === activeId) record(u, display(u))
        }

        function record(url, label) {
          if (!url || url === homeUrl) return
          try {
            fetch(origin + "/browser/history?url=" + encodeURIComponent(url) +
                  "&label=" + encodeURIComponent(label || url), {method: "POST"})
          } catch (e) {}
        }

        function go() {
          const url = resolve(addr.value)
          if (url) inv("browser_navigate", { tabId: activeId, url })
        }
        // "/"-prefixed addresses browse the workspace in the active tab (debounced).
        let browseTimer
        addr.addEventListener("input", function () {
          if (!addr.value.startsWith("/")) return
          clearTimeout(browseTimer)
          browseTimer = setTimeout(function () {
            if (addr.value.startsWith("/")) {
              inv("browser_navigate", {
                tabId: activeId,
                url: origin + "/browser/workspace?q=" + encodeURIComponent(addr.value)
              })
            }
          }, 300)
        })

        function bookmark() {
          // Bookmark what the address bar actually shows for the active tab,
          // resolved back to a full URL. This stays correct even when a
          // programmatic navigation didn't fire the content-navigated callback —
          // which would otherwise leave activeTab().url stale and re-bookmark the
          // previous page (so changing the URL appeared to make no new bookmark).
          const t = activeTab()
          const url = resolve(addr.value) || (t && t.url)
          if (!url || url === homeUrl) return
          const label = (t && t.label && t.label !== "New tab" && t.label) || display(url) || url
          const btn = document.getElementById("bookmark")
          fetch(origin + "/browser/bookmarks?url=" + encodeURIComponent(url) +
                "&label=" + encodeURIComponent(label), {method: "POST"})
            .then(function () {
              btn.textContent = "Saved \\u2713"
              setTimeout(function () { btn.textContent = "+ Bookmark" }, 1500)
              loadBookmarks()
            })
            .catch(function () {})
        }

        document.getElementById("form").addEventListener("submit", function (e) { e.preventDefault(); go() })
        document.getElementById("home").addEventListener("click", function () { inv("browser_navigate", { tabId: activeId, url: homeUrl }) })
        document.getElementById("back").addEventListener("click", function () { inv("browser_back", { tabId: activeId }) })
        document.getElementById("fwd").addEventListener("click", function () { inv("browser_forward", { tabId: activeId }) })
        document.getElementById("reload").addEventListener("click", function () { inv("browser_reload", { tabId: activeId }) })
        document.getElementById("bookmark").addEventListener("click", bookmark)

        renderTabs()
        loadBookmarks()
        addr.focus()
      </script>
    </body>
    </html>
    """
  end

  defp escape_attr(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
