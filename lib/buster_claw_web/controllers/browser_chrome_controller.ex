defmodule BusterClawWeb.BrowserChromeController do
  @moduledoc """
  The embedded browser's native chrome — a **tab strip** + a toolbar (back/forward/
  reload + address bar + bookmark), loaded into a `browser-chrome-<sid>` child
  webview. Served from the Phoenix origin so it can call the `browser_*` Tauri
  commands (granted via the `browser-chrome` capability, whose `browser-chrome-*`
  glob covers every surface).

  This controller is a thin HTML shell: layout + styles only. The behavior lives
  in `assets/js/chrome.js` (its own esbuild entry point, served as
  `/assets/js/chrome.js`), which owns the tab-strip UI and tab lifecycle; Rust
  owns the per-tab content webviews and the per-surface active-tab pointer.

  `?sid=` identifies the browser surface this chrome drives (`main` for the solo
  `/browse`, `left`/`right` for a browser+browser split); it's handed to the JS
  via `<body data-sid>` and every `browser_*` invoke carries it so two
  side-by-side browsers stay independent.
  """
  use BusterClawWeb, :controller

  # Omnibox search engine: query text is appended to this prefix. Overridable
  # via the `browser_search_url` setting; DuckDuckGo default fits the app's
  # no-third-party-reporting posture.
  @default_search_url "https://duckduckgo.com/?q="

  def show(conn, params) do
    initial = params["url"] || ""
    sid = sanitize_sid(params["sid"])
    search_url = BusterClaw.Settings.get("browser_search_url", @default_search_url)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(initial, sid, search_url))
  end

  # Surface ids are alphanumeric only (matches the Rust sanitiser); default "main".
  defp sanitize_sid(sid) do
    case sid |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "") do
      "" -> "main"
      cleaned -> cleaned
    end
  end

  defp page(initial, sid, search_url) do
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
      /* The chrome webview covers the surface's WHOLE box. Only two bands are
         ever visible: #top (app tabs + toolbar + bookmark bar) and #sidebar
         (the vertical browser-tab strip). The remaining area (#void) sits
         permanently under the content webview. --sidebar-w MUST match the Rust
         content_box() math (SIDEBAR_WIDTH / SIDEBAR_MAX_FRACTION). */
      :root { --sidebar-w: min(220px, 35vw); }
      body {
        position: relative;
        display: flex; flex-direction: column; height: 100%;
        background: #121212; color: #f4f1ea;
        font: 13px/1 -apple-system, system-ui, sans-serif;
      }
      #top { display: flex; flex-direction: column; flex: 0 0 auto; height: 112px;
             border-bottom: 2px solid rgba(244,241,234,.18); }
      #main { display: flex; flex: 1 1 auto; min-height: 0; }
      #sidebar { display: flex; flex-direction: row; flex: 0 0 auto;
                 width: var(--sidebar-w); min-height: 0;
                 border-right: 2px solid rgba(244,241,234,.18); }
      #void { flex: 1 1 auto; }
      /* Bumper: a full-height strip on the sidebar's edge; click (or ⌘B, via
         the Tabs menu → __menuShortcut) collapses the sidebar to just this
         strip. Collapsed width MUST match Rust's SIDEBAR_COLLAPSED_WIDTH (16 =
         14px bumper + the sidebar's 2px border). */
      #bumper { flex: 0 0 14px; display: flex; flex-direction: column;
                align-items: center; justify-content: center; gap: 8px;
                cursor: pointer; background: transparent; border: none; padding: 0;
                border-left: 1px solid rgba(244,241,234,.1);
                color: rgba(244,241,234,.45); font-size: 11px; line-height: 1; }
      #bumper:hover { color: #ff4d1c; background: rgba(255,77,28,.08); }
      #bumper .glyph { font-size: 12px; }
      #bumper .word { writing-mode: vertical-rl; font: 700 9px/1 ui-monospace, monospace;
                      letter-spacing: .2em; text-transform: uppercase; display: none; }
      body.sidebar-collapsed { --sidebar-w: 16px; }
      body.sidebar-collapsed #tabs { display: none; }
      body.sidebar-collapsed #bumper { border-left: none; }
      body.sidebar-collapsed #bumper .word { display: block; }
      /* loading affordance: indeterminate hazard-orange bar across the top, shown
         while the active tab is loading. Overlaid (absolute) so it adds no layout
         height. */
      #progress { position: absolute; top: 0; left: 0; right: 0; height: 2px;
                  overflow: hidden; pointer-events: none; opacity: 0;
                  transition: opacity .15s; z-index: 5; }
      #progress.on { opacity: 1; }
      #progress::after { content: ""; display: block; height: 100%; width: 35%;
                         background: #ff4d1c; }
      #progress.on::after { animation: ic-load 1s ease-in-out infinite; }
      @keyframes ic-load { 0% { margin-left: -35%; } 100% { margin-left: 100%; } }
      @keyframes ic-spin { to { transform: rotate(360deg); } }
      /* top row: the app-tab switcher (browser tabs live in the sidebar now).
         Styled to MATCH the app's own TabStrip (layouts.ex / tab_strip.js):
         a bg-base-200/80 strip with a base-300 bottom border, browser-style
         rounded-top chips sitting on it. Theme tokens are hardcoded from the
         dark theme in app.css (base-100 #121212, base-200 #0c0c0c, base-300
         #1f1f1f, base-content #fafafa) — the chrome page has no Tailwind. */
      #row { display: flex; align-items: stretch; height: 34px; min-width: 0;
             background: rgba(12,12,12,.8); border-bottom: 1px solid #1f1f1f; }
      /* App-tab chips: the native browser webviews cover the app's DOM tab
         strip, so the chrome carries its own switcher (Home + open app tabs). */
      #apptabs { display: flex; align-items: flex-end; gap: 4px; flex: 1 1 auto;
                 min-width: 0; padding: 4px 8px 0 8px; overflow-x: auto;
                 overflow-y: hidden; }
      #apptabs::-webkit-scrollbar { height: 0; }
      .atab { display: flex; align-items: center; flex: 0 0 auto; max-width: 192px;
              height: 29px; padding: 0 12px; cursor: pointer;
              background: #0c0c0c; color: rgba(250,250,250,.6);
              border: 1px solid transparent; border-bottom: none;
              border-radius: 8px 8px 0 0;
              font: 400 14px/1 -apple-system, system-ui, sans-serif;
              white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .atab:hover { background: rgba(18,18,18,.7); color: #fafafa; }
      .atab.current { background: #121212; color: #fafafa; font-weight: 500;
                      border-color: #1f1f1f; cursor: default; }
      /* browser tab strip — vertical, in the sidebar */
      #tabs { display: flex; flex-direction: column; align-items: stretch; gap: 4px;
              flex: 1 1 auto; min-height: 0; padding: 8px 6px;
              overflow-y: auto; overflow-x: hidden; }
      #tabs::-webkit-scrollbar { width: 0; }
      .tab { display: flex; align-items: center; gap: 6px; width: 100%;
             padding: 0 8px; height: 30px; cursor: pointer; flex: 0 0 auto;
             background: #1c1c1c; color: rgba(244,241,234,.6);
             border: 1px solid rgba(244,241,234,.14); border-radius: 4px; }
      .tab.active { background: #2a2a2a; color: #f4f1ea; border-color: rgba(244,241,234,.3); }
      /* Ephemeral (agent sandbox) tabs: dashed outline — the session dies with
         the tab and it's excluded from session restore. */
      .tab.eph { border-style: dashed; border-color: rgba(255,77,28,.45); }
      .tab.eph.active { border-color: rgba(255,77,28,.7); }
      /* Suspended (background-tab eviction freed the webview): dimmed to signal
         a click will reload it. The chip and its URL survive. */
      .tab.suspended .label { opacity: .5; font-style: italic; }
      .tab .label { flex: 1 1 auto; min-width: 0; overflow: hidden;
                    text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
      .tab .fav { width: 14px; height: 14px; flex: 0 0 auto; border-radius: 3px; }
      .tab .spin { width: 12px; height: 12px; flex: 0 0 auto; border-radius: 50%;
                   border: 2px solid rgba(244,241,234,.25); border-top-color: #ff4d1c;
                   animation: ic-spin .7s linear infinite; }
      .tab .x { display: grid; place-items: center; width: 16px; height: 16px;
                border-radius: 3px; color: rgba(244,241,234,.45); font-size: 13px;
                flex: 0 0 auto; }
      .tab .x:hover { background: rgba(244,241,234,.12); color: #ff4d1c; }
      /* New tab / new private: a row pinned under the tab list. */
      .newrow { display: flex; gap: 4px; flex: 0 0 auto; }
      #newtab, #newprivate { flex: 1 1 0; height: 28px; display: grid;
                place-items: center; background: transparent; color: #f4f1ea;
                border: 1px solid rgba(244,241,234,.2); border-radius: 4px;
                cursor: pointer; font-size: 16px; line-height: 1; }
      #newtab:hover, #newprivate:hover { border-color: #ff4d1c; color: #ff4d1c; }
      /* Private-tab button: dashed hazard outline, echoing the .tab.eph chips. */
      #newprivate { border-style: dashed; border-color: rgba(255,77,28,.45);
                    font-size: 13px; }
      /* toolbar */
      #toolbar { display: flex; align-items: center; gap: 6px; padding: 0 8px;
                 height: 46px; }
      button.nav {
        flex: 0 0 auto; width: 30px; height: 30px; display: grid; place-items: center;
        background: transparent; color: #f4f1ea; border: 2px solid rgba(244,241,234,.2);
        border-radius: 3px; cursor: pointer; font-size: 14px; line-height: 1;
      }
      button.nav:hover { border-color: #ff4d1c; color: #ff4d1c; }
      /* TLS indicator: a padlock left of the address bar. Muted for HTTPS, a
         hazard-orange warning for plaintext HTTP; hidden for our own workspace
         pages and blank tabs. */
      .secure { flex: 0 0 auto; display: none; place-items: center; width: 20px;
                height: 30px; font-size: 12px; cursor: default; }
      .secure.https { display: grid; color: rgba(244,241,234,.55); }
      .secure.http { display: grid; color: #ff4d1c; }
      /* Content-blocking shield: lit (hazard-orange) when blocking is on,
         dimmed when off. Title is set from JS to reflect state. */
      button.shield { font-size: 13px; }
      button.shield.on { border-color: #ff4d1c; color: #ff4d1c;
                         background: rgba(255,77,28,.12); }
      button.shield.off { opacity: .5; }
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
      /* bottom row: downloads shelf (left, only while present) + bookmark bar */
      #row2 { display: flex; align-items: center; height: 32px; min-width: 0;
              border-top: 1px solid rgba(244,241,234,.1); }
      #downloads { display: flex; align-items: center; gap: 4px; flex: 0 0 auto;
                   max-width: 45%; padding: 0 0 0 8px; overflow-x: auto;
                   overflow-y: hidden; }
      #downloads:not(:empty) { padding-right: 8px; margin-right: 4px;
                               border-right: 1px solid rgba(244,241,234,.14); }
      #downloads::-webkit-scrollbar { height: 0; }
      .dl { display: flex; align-items: center; gap: 6px; flex: 0 0 auto;
            max-width: 220px; height: 24px; padding: 0 8px; background: #1c1c1c;
            color: rgba(244,241,234,.75); border: 1px solid rgba(244,241,234,.2);
            border-radius: 4px; font: 600 11px/1 ui-monospace, monospace;
            white-space: nowrap; }
      .dl .t { overflow: hidden; text-overflow: ellipsis; }
      .dl.done { cursor: pointer; }
      .dl.done:hover { color: #f4f1ea; border-color: rgba(244,241,234,.45); }
      .dl.failed { color: #ff4d1c; border-color: rgba(255,77,28,.5); }
      .dl .spin { width: 10px; height: 10px; flex: 0 0 auto; border-radius: 50%;
                  border: 2px solid rgba(244,241,234,.25); border-top-color: #ff4d1c;
                  animation: ic-spin .7s linear infinite; }
      /* bookmark bar */
      #bookmarkbar { display: flex; align-items: center; gap: 4px; flex: 1 1 auto;
                     min-width: 0; height: 32px; padding: 0 8px 0 0;
                     overflow-x: auto; overflow-y: hidden; }
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
      /* omnibox suggestion chips (take over the bookmark row while typing) */
      .sug { display: flex; align-items: center; gap: 6px; flex: 0 0 auto; max-width: 220px;
             height: 24px; padding: 0 8px; cursor: pointer; background: #1c1c1c;
             color: rgba(244,241,234,.75); border: 1px solid rgba(244,241,234,.2);
             border-radius: 4px; font: 12px/1 -apple-system, system-ui, sans-serif;
             white-space: nowrap; }
      .sug .k { color: rgba(244,241,234,.4); font-size: 10px; flex: 0 0 auto; }
      .sug .t { overflow: hidden; text-overflow: ellipsis; }
      .sug:hover, .sug.sel { color: #f4f1ea; border-color: #ff4d1c; }
      .sug.sel { background: rgba(255,77,28,.14); }
      /* find-in-page bar (takes over the bookmark row while open) */
      .findbar { display: flex; align-items: center; gap: 4px; flex: 1 1 auto; min-width: 0; }
      #find { flex: 0 1 320px; min-width: 120px; height: 24px; padding: 0 8px;
              background: #1c1c1c; color: #f4f1ea; border: 1px solid rgba(244,241,234,.2);
              border-radius: 4px; font: 12px/1 ui-monospace, monospace; outline: none; }
      #find:focus { border-color: rgba(255,77,28,.6); }
      .fbtn { display: grid; place-items: center; width: 24px; height: 24px; flex: 0 0 auto;
              background: transparent; color: rgba(244,241,234,.7);
              border: 1px solid rgba(244,241,234,.2); border-radius: 4px; cursor: pointer;
              font-size: 13px; line-height: 1; }
      .fbtn:hover { border-color: #ff4d1c; color: #ff4d1c; }
      .fcount { flex: 0 0 auto; padding: 0 4px; color: rgba(244,241,234,.55);
                font: 11px/1 ui-monospace, monospace; white-space: nowrap; }
      .fcount.none { color: #ff4d1c; }
    </style>
    </head>
    <body data-sid="#{sid}" data-search-url="#{escape_attr(search_url)}">
      <div id="progress"></div>
      <div id="top">
        <div id="row">
          <div id="apptabs" role="tablist" aria-label="App tabs"></div>
        </div>
        <div id="toolbar">
          <button class="nav" id="home" title="Home" aria-label="Home">&#8962;</button>
          <button class="bm" id="pages" title="Pages — HTML the agent built for you">Pages</button>
          <button class="nav" id="back" title="Back" aria-label="Back">&#9664;</button>
          <button class="nav" id="fwd" title="Forward" aria-label="Forward">&#9654;</button>
          <button class="nav" id="reload" title="Reload" aria-label="Reload">&#8635;</button>
          <span id="secure" class="secure" aria-hidden="true"></span>
          <form id="form">
            <input id="addr" type="text" autocomplete="off" spellcheck="false"
                   placeholder="Search, https://…, or /path in your workspace"
                   value="#{escape_attr(initial)}" />
            <button class="go" type="submit">Go</button>
          </form>
          <button class="nav shield" id="shield" type="button" aria-label="Content blocking">&#128737;</button>
          <button class="bm" id="bookmark" type="button" title="Bookmark this page">+ Bookmark</button>
        </div>
        <div id="row2">
          <div id="downloads"></div>
          <div id="bookmarkbar"></div>
        </div>
      </div>
      <div id="main">
        <div id="sidebar">
          <div id="tabs" role="tablist" aria-label="Browser tabs"></div>
          <button id="bumper" type="button" aria-label="Toggle tab sidebar">
            <span class="glyph"></span>
            <span class="word">Tabs</span>
          </button>
        </div>
        <div id="void" aria-hidden="true"></div>
      </div>
      <script src="/assets/js/chrome.js"></script>
    </body>
    </html>
    """
  end

  defp escape_attr(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
