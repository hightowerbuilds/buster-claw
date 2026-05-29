const http = require("http")

let playwright = null
let loadError = null

try {
  playwright = require("playwright")
} catch (error) {
  loadError = error
}

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

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    sendJson(res, playwright ? 200 : 503, {
      ok: Boolean(playwright),
      playwright: Boolean(playwright),
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

  sendJson(res, 404, {error: "not found"})
})

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
