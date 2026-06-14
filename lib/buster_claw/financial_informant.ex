defmodule BusterClaw.FinancialInformant do
  @moduledoc """
  Generates `financial-informant.html` — the Financial Informant as a
  self-contained, dark-themed HTML page (CSS + JS inline). It replicates the
  former `FinanceLive` LiveView: ticker/company typeahead, per-stock in-page
  tabs, and Quote / Fundamentals / Filings / News cards, each stamped with its
  source + as-of and labelled "not financial advice."

  The page is static markup; all data is fetched client-side from the loopback
  JSON surface (`/finance/api/search`, `/finance/api/lookup`) served by
  `BusterClawWeb.FinanceApiController`. Installed into `<workspace>/pages/` by
  `BusterClaw.Pages` and opened in the in-app browser.
  """

  @doc "The full Financial Informant page as one self-contained HTML document."
  def html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Financial Informant</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; }
      body {
        background: #121212; color: #f4f1ea; padding: 40px 28px 80px;
        font: 15px/1.5 -apple-system, system-ui, sans-serif;
      }
      .wrap { max-width: 60rem; margin: 0 auto; }
      .eyebrow { font: 700 11px/1 ui-monospace, monospace; letter-spacing: .12em;
                 text-transform: uppercase; color: rgba(244,241,234,.5); }
      h1 { margin: 6px 0 8px; font-size: 28px; font-weight: 900; letter-spacing: -.01em; }
      .lede { margin: 0 0 18px; color: rgba(244,241,234,.7); font-size: 14px; }
      .lede b { color: #f4f1ea; }
      .search { position: relative; display: flex; gap: 8px; flex-wrap: wrap;
                align-items: flex-start; border-top: 1px solid rgba(244,241,234,.12);
                padding-top: 18px; }
      .field { position: relative; width: 22rem; max-width: 100%; }
      input { width: 100%; height: 38px; padding: 0 12px; background: #1c1c1c;
              color: #f4f1ea; border: 2px solid rgba(244,241,234,.2); border-radius: 3px;
              font: 13px/1 ui-monospace, monospace; outline: none; }
      input:focus { border-color: rgba(244,241,234,.45); }
      .suggest { position: absolute; z-index: 20; top: 42px; left: 0; right: 0;
                 max-height: 18rem; overflow: auto; background: #1c1c1c;
                 border: 2px solid rgba(244,241,234,.25); border-radius: 3px;
                 list-style: none; margin: 0; padding: 0; display: none; }
      .suggest li button { display: flex; gap: 8px; align-items: baseline; width: 100%;
                 text-align: left; padding: 9px 12px; background: transparent; border: 0;
                 color: #f4f1ea; cursor: pointer; font-size: 13px; }
      .suggest li button:hover { background: rgba(244,241,234,.08); }
      .suggest .sym { font: 700 13px/1 ui-monospace, monospace; flex: 0 0 auto; }
      .suggest .nm { color: rgba(244,241,234,.6); overflow: hidden;
                     text-overflow: ellipsis; white-space: nowrap; }
      button.go { height: 38px; padding: 0 18px; cursor: pointer; background: #ff4d1c;
                  color: #121212; border: 0; border-radius: 3px; font-weight: 700; font-size: 13px; }
      .notice { margin: 12px 0 0; font: 12px/1.4 ui-monospace, monospace; color: #f0a020; }
      .empty { margin-top: 28px; border: 1px dashed rgba(244,241,234,.2); border-radius: 4px;
               padding: 56px 20px; text-align: center; color: rgba(244,241,234,.55); }
      .tabs { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 26px;
              border-bottom: 2px solid rgba(244,241,234,.18); }
      .tab { display: flex; align-items: center; gap: 8px; padding: 8px 12px;
             border: 2px solid transparent; border-bottom: 0; border-radius: 3px 3px 0 0;
             color: rgba(244,241,234,.55); cursor: default; }
      .tab.active { border-color: rgba(244,241,234,.3); background: #161616; color: #f4f1ea; }
      .tab .pick { background: transparent; border: 0; color: inherit; cursor: pointer;
                   display: flex; gap: 8px; align-items: baseline; padding: 0; }
      .tab .pick .sym { font: 700 13px/1 ui-monospace, monospace; }
      .tab .pick .nm { font-size: 12px; color: rgba(244,241,234,.55); max-width: 12rem;
                       overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .tab .x { background: transparent; border: 0; color: rgba(244,241,234,.4);
                cursor: pointer; font-size: 15px; line-height: 1; padding: 0 2px; }
      .tab .x:hover { color: #ff4d1c; }
      .stock-title { margin: 26px 0 16px; font-size: 22px; font-weight: 900;
                     letter-spacing: -.01em; }
      .stock-title .sym { margin-left: 6px; font: 16px/1 ui-monospace, monospace;
                          color: rgba(244,241,234,.5); }
      .cards { display: grid; gap: 18px; grid-template-columns: 1fr; }
      @media (min-width: 52rem) { .cards { grid-template-columns: 1fr 1fr; } }
      .card { border: 1px solid rgba(244,241,234,.14); border-radius: 4px; padding: 18px;
              background: #161616; }
      .card h2 { margin: 0 0 12px; font-size: 16px; font-weight: 800; text-transform: uppercase;
                 letter-spacing: .02em; }
      .price { display: flex; align-items: baseline; gap: 12px; }
      .price .big { font-size: 30px; font-weight: 900; }
      .chg { font: 600 13px/1 ui-monospace, monospace; }
      .up { color: #4ade80; } .down { color: #f87171; } .flat { color: rgba(244,241,234,.6); }
      dl.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 2px 24px; margin: 12px 0 0;
                font: 12px/1.6 ui-monospace, monospace; color: rgba(244,241,234,.72); }
      dl.grid > div { display: flex; justify-content: space-between; }
      .facts { margin: 8px 0 0; }
      .facts .row { display: flex; justify-content: space-between; gap: 12px;
                    padding: 7px 0; border-top: 1px solid rgba(244,241,234,.1); }
      .facts .row:first-child { border-top: 0; }
      .facts dt { color: rgba(244,241,234,.72); }
      .facts dd { margin: 0; text-align: right; }
      .facts .val { font: 600 13px/1.3 ui-monospace, monospace; }
      .facts .meta { font: 10px/1.3 ui-monospace, monospace; text-transform: uppercase;
                     letter-spacing: .04em; color: rgba(244,241,234,.45); }
      .facts .na { font: 12px/1 ui-monospace, monospace; color: rgba(244,241,234,.4); }
      ul.rows { list-style: none; margin: 0; padding: 0; }
      ul.rows li { display: flex; justify-content: space-between; gap: 12px; align-items: center;
                   padding: 8px 0; border-top: 1px solid rgba(244,241,234,.1); font-size: 13px; }
      ul.rows li:first-child { border-top: 0; }
      .badge { background: rgba(244,241,234,.1); border-radius: 3px; padding: 2px 7px;
               font: 700 11px/1.3 ui-monospace, monospace; }
      .when { font: 11px/1.3 ui-monospace, monospace; color: rgba(244,241,234,.6); }
      .news li { display: block; }
      .news a { color: #ff4d1c; text-decoration: none; font-weight: 600; }
      .news a:hover { text-decoration: underline; }
      .news .src { margin-top: 3px; font: 10px/1.3 ui-monospace, monospace; text-transform: uppercase;
                   letter-spacing: .04em; color: rgba(244,241,234,.5); }
      a.view { color: #ff4d1c; text-decoration: none; font: 11px/1 ui-monospace, monospace; flex: 0 0 auto; }
      a.view:hover { text-decoration: underline; }
      .prov { margin: 14px 0 0; border-top: 1px solid rgba(244,241,234,.12); padding-top: 8px;
              font: 10px/1.3 ui-monospace, monospace; text-transform: uppercase;
              letter-spacing: .04em; color: rgba(244,241,234,.45); }
      .muted { color: rgba(244,241,234,.6); font-size: 13px; }
      .warn { color: #f0a020; font: 12px/1.4 ui-monospace, monospace; }
      code { background: rgba(244,241,234,.1); padding: 1px 5px; border-radius: 3px;
             font: 12px/1 ui-monospace, monospace; }
    </style>
    </head>
    <body>
      <div class="wrap">
        <p class="eyebrow">Markets</p>
        <h1>Financial Informant</h1>
        <p class="lede">
          Search by ticker or company name — opens in a tab below. Every figure carries its
          source and as-of date. <b>Not financial advice.</b>
        </p>

        <form class="search" id="search-form" autocomplete="off">
          <div class="field">
            <input id="q" type="text" spellcheck="false"
                   placeholder="Ticker or company — e.g. AAPL or Apple" />
            <ul class="suggest" id="suggest"></ul>
          </div>
          <button class="go" type="submit">Look up</button>
        </form>
        <p class="notice" id="notice" style="display:none"></p>

        <div class="empty" id="empty">
          No stocks open. Search above to open one — each opens in its own tab here.
        </div>

        <div id="board" style="display:none">
          <div class="tabs" id="tabs" role="tablist"></div>
          <div id="content"></div>
        </div>
      </div>

      <script>
        const origin = window.location.origin
        const tabs = []
        let active = null

        const $ = (id) => document.getElementById(id)
        const el = (tag, cls, text) => {
          const n = document.createElement(tag)
          if (cls) n.className = cls
          if (text != null) n.textContent = text
          return n
        }
        const httpLink = (url, text, cls) => {
          const a = el("a", cls, text)
          if (typeof url === "string" && /^https?:\\/\\//i.test(url)) {
            a.href = url; a.target = "_blank"; a.rel = "noopener"
          }
          return a
        }

        // --- formatting (mirrors the former LiveView) ---
        const num = (v) => (typeof v === "number" && isFinite(v))
        const fmtPrice = (v) => num(v) ? "$" + v.toFixed(2) : "—"
        const fmtSigned = (v) => num(v) ? (v > 0 ? "+" : "") + v.toFixed(2) : "—"
        const fmtNumber = (v) => num(v) ? Math.round(v).toLocaleString("en-US") : String(v)
        const changeClass = (v) => !num(v) ? "flat" : v < 0 ? "down" : v > 0 ? "up" : "flat"
        const pad = (n) => String(n).padStart(2, "0")
        const fmtDate = (iso) => {
          if (!iso) return "—"
          const d = new Date(iso)
          if (isNaN(d.getTime())) return String(iso)
          return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) +
                 " " + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + " UTC"
        }

        // --- data ---
        async function getJSON(path) {
          const res = await fetch(origin + path, { headers: { accept: "application/json" } })
          return res.json()
        }
        const suggest = async (q) => {
          const r = await getJSON("/finance/api/search?q=" + encodeURIComponent(q))
          return (r && r.ok && Array.isArray(r.suggestions)) ? r.suggestions : []
        }
        const lookup = async (q) => getJSON("/finance/api/lookup?q=" + encodeURIComponent(q))

        // --- card builders ---
        function provenance(card, sec) {
          if (sec && sec.data) card.appendChild(el("p", "prov",
            "Source: " + (sec.data.source || "—") + " · as of " + fmtDate(sec.data.as_of)))
        }
        function notConfigured(card) {
          const p = el("p", "muted")
          p.append("Not configured. Set ")
          p.appendChild(el("code", null, "FINNHUB_API_KEY"))
          p.append(" and restart to enable live quotes and news.")
          card.appendChild(p)
        }
        function sectionError(card, sec) {
          if (sec && sec.not_configured) return notConfigured(card)
          card.appendChild(el("p", "warn", (sec && sec.error) || "Couldn't fetch."))
        }

        function quoteCard(sec) {
          const card = el("div", "card"); card.appendChild(el("h2", null, "Quote"))
          if (!sec || !sec.ok) { sectionError(card, sec); return card }
          const q = sec.data
          const line = el("div", "price")
          line.appendChild(el("span", "big", fmtPrice(q.price)))
          line.appendChild(el("span", "chg " + changeClass(q.change),
            fmtSigned(q.change) + " (" + fmtSigned(q.percent_change) + "%)"))
          card.appendChild(line)
          const dl = el("dl", "grid")
          const pair = (k, v) => { const d = el("div"); d.appendChild(el("dt", null, k));
            d.appendChild(el("dd", null, fmtPrice(v))); dl.appendChild(d) }
          pair("Open", q.open); pair("Prev close", q.previous_close)
          pair("High", q.high); pair("Low", q.low)
          card.appendChild(dl)
          if (q.note) card.appendChild(el("p", "muted", q.note))
          provenance(card, sec)
          return card
        }

        function fundamentalsCard(sec) {
          const card = el("div", "card"); card.appendChild(el("h2", null, "Fundamentals"))
          if (!sec || !sec.ok) { sectionError(card, sec); return card }
          const f = sec.data
          card.appendChild(el("p", "muted", f.company || ""))
          const facts = el("dl", "facts")
          const labels = [["Revenue","revenue"],["Net income","net_income"],["Assets","assets"],
            ["Liabilities","liabilities"],["Shareholders' equity","stockholders_equity"]]
          labels.forEach(([label, key]) => {
            const fact = f.facts && f.facts[key]
            const row = el("div", "row"); row.appendChild(el("dt", null, label))
            const dd = el("dd")
            if (!fact) { dd.appendChild(el("span", "na", "unavailable")) }
            else {
              dd.appendChild(el("span", "val", fmtNumber(fact.value) + " " + (fact.unit || "")))
              dd.appendChild(el("span", "meta", (fact.form || "") + " · as of " + (fact.as_of || "")))
            }
            row.appendChild(dd); facts.appendChild(row)
          })
          card.appendChild(facts)
          provenance(card, sec)
          return card
        }

        function filingsCard(sec) {
          const card = el("div", "card"); card.appendChild(el("h2", null, "Recent Filings"))
          if (!sec || !sec.ok) { sectionError(card, sec); return card }
          const list = (sec.data.filings || [])
          if (!list.length) { card.appendChild(el("p", "muted", "No recent filings.")); return card }
          const ul = el("ul", "rows")
          list.forEach((f) => {
            const li = el("li")
            const left = el("span"); left.style.display = "flex"; left.style.gap = "8px"
            left.style.alignItems = "center"
            left.appendChild(el("span", "badge", f.form || "—"))
            left.appendChild(el("span", "when", f.filing_date || ""))
            li.appendChild(left)
            if (f.url) li.appendChild(httpLink(f.url, "view ↗", "view"))
            ul.appendChild(li)
          })
          card.appendChild(ul)
          provenance(card, sec)
          return card
        }

        function newsCard(sec) {
          const card = el("div", "card"); card.appendChild(el("h2", null, "News"))
          if (!sec || !sec.ok) { sectionError(card, sec); return card }
          const list = (sec.data.articles || [])
          if (!list.length) { card.appendChild(el("p", "muted", "No recent news.")); return card }
          const ul = el("ul", "rows news")
          list.forEach((a) => {
            const li = el("li")
            li.appendChild(httpLink(a.url, a.headline || "(untitled)"))
            li.appendChild(el("p", "src", (a.source || "—") + " · " + fmtDate(a.as_of)))
            ul.appendChild(li)
          })
          card.appendChild(ul)
          provenance(card, sec)
          return card
        }

        // --- tabs + render ---
        function render() {
          const board = $("board"), empty = $("empty")
          if (!tabs.length) { board.style.display = "none"; empty.style.display = "block"; return }
          empty.style.display = "none"; board.style.display = "block"

          const strip = $("tabs"); strip.textContent = ""
          tabs.forEach((t) => {
            const tab = el("div", "tab" + (t.symbol === active ? " active" : ""))
            const pick = el("button", "pick"); pick.type = "button"
            pick.appendChild(el("span", "sym", t.symbol))
            pick.appendChild(el("span", "nm", t.name))
            pick.onclick = () => { active = t.symbol; render() }
            tab.appendChild(pick)
            const x = el("button", "x", "×"); x.type = "button"
            x.setAttribute("aria-label", "Close " + t.symbol)
            x.onclick = () => closeTab(t.symbol)
            tab.appendChild(x)
            strip.appendChild(tab)
          })

          const content = $("content"); content.textContent = ""
          const t = tabs.find((x) => x.symbol === active)
          if (!t) return
          const title = el("h2", "stock-title", t.name)
          title.appendChild(el("span", "sym", t.symbol))
          content.appendChild(title)
          const cards = el("div", "cards")
          cards.appendChild(quoteCard(t.data.quote))
          cards.appendChild(fundamentalsCard(t.data.fundamentals))
          cards.appendChild(filingsCard(t.data.filings))
          cards.appendChild(newsCard(t.data.news))
          content.appendChild(cards)
        }

        function closeTab(symbol) {
          const i = tabs.findIndex((t) => t.symbol === symbol)
          if (i < 0) return
          tabs.splice(i, 1)
          if (active === symbol) active = tabs.length ? tabs[tabs.length - 1].symbol : null
          render()
        }

        function openTab(payload) {
          const existing = tabs.find((t) => t.symbol === payload.symbol)
          if (existing) { active = existing.symbol; render(); return }
          tabs.push({ symbol: payload.symbol, name: payload.name || payload.symbol, data: payload })
          active = payload.symbol
          render()
        }

        // --- search wiring ---
        const q = $("q"), box = $("suggest"), notice = $("notice")
        const showNotice = (msg) => { notice.textContent = msg; notice.style.display = msg ? "block" : "none" }
        const hideSuggest = () => { box.style.display = "none"; box.textContent = "" }

        const renderSuggest = (items) => {
          box.textContent = ""
          if (!items.length) { hideSuggest(); return }
          items.forEach((s) => {
            const li = document.createElement("li")
            const b = el("button"); b.type = "button"
            b.appendChild(el("span", "sym", s.symbol))
            b.appendChild(el("span", "nm", s.name || ""))
            b.onclick = () => doLookup(s.symbol)
            li.appendChild(b); box.appendChild(li)
          })
          box.style.display = "block"
        }

        let timer
        q.addEventListener("input", () => {
          showNotice("")
          const v = q.value.trim()
          clearTimeout(timer)
          if (v.length < 2) { hideSuggest(); return }
          timer = setTimeout(async () => { renderSuggest(await suggest(v)) }, 200)
        })

        async function doLookup(raw) {
          const query = (raw || "").trim()
          hideSuggest()
          if (!query) return
          showNotice("")
          const r = await lookup(query)
          if (!r || !r.ok) { showNotice(r && r.error ? r.error : "No company found for “" + query + "”.") ; return }
          q.value = ""
          openTab(r)
        }

        $("search-form").addEventListener("submit", (e) => { e.preventDefault(); doLookup(q.value) })
        document.addEventListener("click", (e) => {
          if (!box.contains(e.target) && e.target !== q) hideSuggest()
        })
        q.focus()
      </script>
    </body>
    </html>
    """
  end
end
