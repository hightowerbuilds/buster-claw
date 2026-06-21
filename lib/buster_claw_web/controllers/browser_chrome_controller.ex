defmodule BusterClawWeb.BrowserChromeController do
  @moduledoc """
  The embedded browser's native chrome — a **tab strip** + a toolbar (back/forward/
  reload + address bar + bookmark), loaded into the `browser-chrome` child webview.
  Served from the Phoenix origin so it can call the `browser_*` Tauri commands
  (granted via the `browser-chrome` capability). It owns the tab-strip UI and tab
  lifecycle; Rust owns the per-tab content webviews and the active-tab pointer.
  """
  use BusterClawWeb, :controller

  def show(conn, params) do
    initial = params["url"] || ""

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(initial))
  end

  defp page(initial) do
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
        display: flex; flex-direction: column; height: 80px;
        background: #121212; color: #f4f1ea;
        font: 13px/1 -apple-system, system-ui, sans-serif;
        border-bottom: 2px solid rgba(244,241,234,.18);
      }
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
    </style>
    </head>
    <body>
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
      <script>
        const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke
        const origin = window.location.origin
        const homeUrl = origin + "/browser/home"
        const addr = document.getElementById("addr")
        const tabsEl = document.getElementById("tabs")

        // Invoke a Tauri command, surfacing failures in the console (so a denied
        // permission or a missing webview is visible rather than silent).
        function inv(cmd, args) {
          if (!invoke) return Promise.resolve()
          return invoke(cmd, args || {}).catch(function (e) {
            console.error("browser " + cmd + " failed:", e)
          })
        }

        // --- tab state (chrome owns the strip; Rust owns the webviews) ---
        let tabs = [{ id: "1", url: "", label: "New tab" }]
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

        function renderTabs() {
          tabsEl.textContent = ""
          tabs.forEach((t) => {
            const tab = document.createElement("div")
            tab.className = "tab" + (t.id === activeId ? " active" : "")
            tab.title = t.label
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
        }

        function activeTab() { return tabs.find((t) => t.id === activeId) }

        function newTab() {
          const id = String(nextId++)
          tabs.push({ id, url: "", label: "New tab" })
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

        // Called from Rust on each content navigation, per tab id.
        window.__onContentNavigated = function (id, u) {
          const t = tabs.find((x) => x.id === id)
          if (t) { t.url = u; t.label = deriveLabel(u) }
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
        addr.focus()
      </script>
    </body>
    </html>
    """
  end

  defp escape_attr(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
