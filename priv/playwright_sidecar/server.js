const http = require("http")
const crypto = require("crypto")

let playwright = null
let loadError = null

try {
  playwright = require("playwright")
} catch (error) {
  loadError = error
}

// Stateful Browserbase sessions: a live Playwright browser/context/page held
// across HTTP calls, keyed by a sidecar-generated id. The Elixir SessionManager
// owns the real lifecycle (create/release billing, idle reaping); this map and
// the defensive sweep below are only a backstop so a crashed BEAM can't leave a
// dead CDP link open forever. Keep IDLE_HARD_MS strictly longer than the Elixir
// idle timeout so the two never race.
const sessions = new Map()
const IDLE_HARD_MS = Number(process.env.BUSTER_CLAW_SIDECAR_IDLE_HARD_MS || 300000)

const sendJson = (res, status, body) => {
  const json = JSON.stringify(body)
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(json)
  })
  res.end(json)
}

const readJson = (req) => {
  return new Promise((resolve, reject) => {
    let body = ""

    req.on("data", chunk => {
      body += chunk
      if (body.length > 1024 * 1024) {
        reject(new Error("request body too large"))
        req.destroy()
      }
    })

    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {})
      } catch (error) {
        reject(error)
      }
    })

    req.on("error", reject)
  })
}

const normalizeCookies = (cookies, url) => {
  if (!cookies) return []

  if (Array.isArray(cookies)) {
    return cookies.map(cookie => ({url, ...cookie}))
  }

  if (typeof cookies === "object") {
    return Object.entries(cookies).map(([name, value]) => ({
      url,
      name,
      value: String(value)
    }))
  }

  return []
}

const fetchPage = async (payload) => {
  if (!playwright) {
    throw new Error(`playwright unavailable: ${loadError && loadError.message}`)
  }

  const engineName = payload.browser || payload.engine || "chromium"
  const engine = playwright[engineName] || playwright.chromium
  const timeout = Number(payload.timeout_ms || 15000)
  const browser = await engine.launch({headless: true})

  try {
    const context = await browser.newContext()
    const cookies = normalizeCookies(payload.cookies, payload.url)

    if (cookies.length > 0) {
      await context.addCookies(cookies)
    }

    const page = await context.newPage()
    page.setDefaultTimeout(timeout)
    await page.goto(payload.url, {
      waitUntil: payload.wait_until || "domcontentloaded",
      timeout
    })
    await page.waitForSelector("body", {timeout})

    return {
      url: page.url(),
      title: await page.title(),
      html: await page.content()
    }
  } finally {
    await browser.close()
  }
}

// Map a Playwright error to a wire status: a dropped CDP link / closed target is
// a 409 (the Browserbase session died underneath us — Elixir reconciles);
// anything else (bad selector, timeout) is a 422.
const classifyError = (message) => {
  const m = String(message || "")
  if (/Target closed|Session closed|WebSocket|has been closed|Browser closed/i.test(m)) {
    return 409
  }
  return 422
}

// Resolve a session id, bump its idle clock, run the handler, and map failures
// to the 404/409/422 wire contract. A missing id is 404 unknown_session — the
// same signal a sidecar restart produces (empty map), so Elixir treats both as
// "handle gone, reconcile".
const withSession = async (id, res, handler) => {
  const entry = sessions.get(id)

  if (!entry) {
    sendJson(res, 404, {error: "unknown_session", id})
    return
  }

  entry.lastUsedAt = Date.now()

  try {
    const body = await handler(entry)
    sendJson(res, 200, body)
  } catch (error) {
    const status = classifyError(error.message)
    sendJson(res, status, {
      error: status === 409 ? "session_closed" : "action_failed",
      id,
      detail: error.message
    })
  }
}

const openSession = async (payload) => {
  if (!playwright) {
    throw new Error(`playwright unavailable: ${loadError && loadError.message}`)
  }

  if (!payload.connectUrl) {
    throw new Error("connectUrl required")
  }

  const timeout = Number(payload.timeout_ms || 15000)
  const browser = await playwright.chromium.connectOverCDP(payload.connectUrl)
  const context = browser.contexts()[0] || (await browser.newContext())
  const page = context.pages()[0] || (await context.newPage())
  page.setDefaultTimeout(timeout)

  const id = "sc_" + crypto.randomUUID()
  const now = Date.now()

  // A dropped Browserbase session fires "disconnected"; forget the handle so the
  // next verb returns 404 unknown_session and Elixir reconciles.
  browser.on("disconnected", () => sessions.delete(id))

  sessions.set(id, {
    id,
    browser,
    context,
    page,
    bbSessionId: payload.bbSessionId || null,
    connectUrl: payload.connectUrl,
    openedAt: now,
    lastUsedAt: now,
    timeoutMs: timeout
  })

  return {id, url: page.url(), title: await page.title()}
}

// Collect interactable candidates with a best-effort stable selector, roles, and
// labels so the agent can target fill/click without guessing the DOM.
const findElements = (page, query, limit) => {
  return page.evaluate(
    ({query, limit}) => {
      const q = (query || "").toLowerCase()
      const nodes = Array.from(
        document.querySelectorAll(
          "input, textarea, select, button, a[href], [role=button], [contenteditable]"
        )
      )

      const describe = el => {
        const label = (
          el.getAttribute("aria-label") ||
          el.getAttribute("placeholder") ||
          el.getAttribute("name") ||
          el.id ||
          el.textContent ||
          ""
        )
          .trim()
          .slice(0, 120)

        let selector = el.tagName.toLowerCase()
        if (el.id) selector = "#" + CSS.escape(el.id)
        else if (el.getAttribute("name")) {
          selector = el.tagName.toLowerCase() + '[name="' + el.getAttribute("name") + '"]'
        }

        const rect = el.getBoundingClientRect()

        return {
          selector,
          tag: el.tagName.toLowerCase(),
          role: el.getAttribute("role") || el.type || el.tagName.toLowerCase(),
          name: label,
          type: el.getAttribute("type") || null,
          href: el.getAttribute("href") || null,
          visible: rect.width > 0 && rect.height > 0
        }
      }

      let out = nodes.map(describe)
      if (q) {
        out = out.filter(
          e => e.name.toLowerCase().includes(q) || e.selector.toLowerCase().includes(q)
        )
      }
      return out.slice(0, limit || 20)
    },
    {query, limit}
  )
}

// Selector-map extraction (no schema inference — intelligence stays remote).
const extractData = (page, spec) => {
  return page.evaluate(spec => {
    const text = el => (el ? (el.textContent || "").trim() : null)

    if (spec && spec.type === "list") {
      return Array.from(document.querySelectorAll(spec.item || "*")).map(row => {
        const obj = {}
        for (const [k, sel] of Object.entries(spec.fields || {})) {
          obj[k] = text(row.querySelector(sel))
        }
        return obj
      })
    }

    const obj = {}
    for (const [k, sel] of Object.entries((spec && spec.fields) || {})) {
      obj[k] = text(document.querySelector(sel))
    }
    return obj
  }, spec)
}

const sessionRoutes = {
  "/session/navigate": (entry, p) =>
    withSessionNavigate(entry, p),
  "/session/read": async entry => ({
    url: entry.page.url(),
    title: await entry.page.title(),
    html: await entry.page.content()
  }),
  "/session/fill": async (entry, p) => {
    await entry.page.fill(p.selector, p.value, {timeout: p.timeout_ms || entry.timeoutMs})
    const readback = await entry.page.inputValue(p.selector).catch(() => null)
    return {
      ok: true,
      selector: p.selector,
      value_len: String(p.value || "").length,
      readback_matches: readback === p.value
    }
  },
  "/session/click": async (entry, p) => {
    await entry.page.click(p.selector, {timeout: p.timeout_ms || entry.timeoutMs})
    return {ok: true, url: entry.page.url(), title: await entry.page.title()}
  },
  "/session/select": async (entry, p) => {
    const target = p.value != null ? p.value : p.label != null ? {label: p.label} : {index: p.index}
    const selected = await entry.page.selectOption(p.selector, target, {
      timeout: p.timeout_ms || entry.timeoutMs
    })
    return {ok: true, selected}
  },
  "/session/find_elements": async (entry, p) => ({
    elements: await findElements(entry.page, p.query, p.limit)
  }),
  "/session/screenshot": async (entry, p) => {
    const buf = await entry.page.screenshot({
      fullPage: Boolean(p.full_page),
      type: "png",
      timeout: p.timeout_ms || entry.timeoutMs
    })
    return {mime: "image/png", base64: buf.toString("base64")}
  },
  "/session/extract": async (entry, p) => ({data: await extractData(entry.page, p.spec)})
}

const withSessionNavigate = async (entry, p) => {
  const timeout = p.timeout_ms || entry.timeoutMs
  const resp = await entry.page.goto(p.url, {
    waitUntil: p.wait_until || "domcontentloaded",
    timeout
  })
  await entry.page.waitForSelector("body", {timeout})
  return {url: entry.page.url(), title: await entry.page.title(), status: resp ? resp.status() : null}
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    sendJson(res, playwright ? 200 : 503, {
      ok: Boolean(playwright),
      playwright: Boolean(playwright),
      sessions: sessions.size,
      error: loadError && loadError.message
    })
    return
  }

  if (req.method === "POST" && req.url === "/fetch") {
    try {
      const payload = await readJson(req)
      const page = await fetchPage(payload)
      sendJson(res, 200, page)
    } catch (error) {
      sendJson(res, 500, {error: error.message})
    }

    return
  }

  if (req.method === "POST" && req.url === "/session/open") {
    try {
      const payload = await readJson(req)
      sendJson(res, 200, await openSession(payload))
    } catch (error) {
      const status = /playwright unavailable/.test(error.message)
        ? 503
        : /connectUrl required/.test(error.message)
          ? 422
          : 409
      sendJson(res, status, {error: "open_failed", detail: error.message})
    }

    return
  }

  // Idempotent close: an unknown id is already-closed, so Elixir reaping never
  // fails on a session the sidecar already dropped.
  if (req.method === "POST" && req.url === "/session/close") {
    try {
      const payload = await readJson(req)
      const entry = sessions.get(payload.id)

      if (entry) {
        sessions.delete(payload.id)
        await entry.browser.close().catch(() => {})
        sendJson(res, 200, {ok: true})
      } else {
        sendJson(res, 200, {ok: true, already_closed: true})
      }
    } catch (error) {
      sendJson(res, 422, {error: "close_failed", detail: error.message})
    }

    return
  }

  if (req.method === "POST" && sessionRoutes[req.url]) {
    const handler = sessionRoutes[req.url]

    try {
      const payload = await readJson(req)
      await withSession(payload.id, res, entry => handler(entry, payload))
    } catch (error) {
      sendJson(res, 400, {error: "bad_request", detail: error.message})
    }

    return
  }

  sendJson(res, 404, {error: "not found"})
})

// Defensive backstop only: close sessions the BEAM never reaped (e.g. it
// crashed). Unref'd so it never keeps the event loop alive on shutdown.
const idleSweep = setInterval(() => {
  const now = Date.now()
  for (const [id, entry] of sessions) {
    if (now - entry.lastUsedAt > IDLE_HARD_MS) {
      sessions.delete(id)
      entry.browser.close().catch(() => {})
    }
  }
}, 30000)
idleSweep.unref()

server.listen(0, "127.0.0.1", () => {
  const address = server.address()
  console.log(JSON.stringify({event: "listening", port: address.port}))
})

server.on("error", error => {
  console.log(JSON.stringify({event: "error", message: error.message}))
})

// Exit when the supervising BEAM port closes our stdin, so we never orphan.
process.stdin.on("end", () => process.exit(0))
process.stdin.on("close", () => process.exit(0))
process.stdin.resume()
