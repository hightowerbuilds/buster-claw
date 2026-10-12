import {actionLabel, edgePath, failed, fitTransform, layoutActivity} from "./browser_activity_model.js"

const NS = "http://www.w3.org/2000/svg"
const short = (text, count = 27) => text.length > count ? text.slice(0, count - 1) + "…" : text
const svg = (tag, attrs = {}, text) => {
  const el = document.createElementNS(NS, tag)
  for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value)
  if (text !== undefined) el.textContent = text
  return el
}

export class BrowserActivityView {
  constructor(el) {
    this.el = el
    this.svg = el.querySelector("[data-graph]")
    this.scene = el.querySelector("[data-scene]")
    this.source = el.querySelector("[data-source]")
    this.run = el.querySelector("[data-run]")
    this.live = true
    this.follow = true
    this.events = []
    this.graph = layoutActivity([])
    this.transform = {x: 0, y: 0, scale: 1}
    this.abort = new AbortController()
    const options = {signal: this.abort.signal}
    el.addEventListener("click", event => this.click(event), options)
    el.addEventListener("keydown", event => {
      if (["Enter", " "].includes(event.key) && event.target.closest("[data-event]")) {
        event.preventDefault()
        this.setFollow(false)
        this.select(Number(event.target.closest("[data-event]").dataset.event))
      }
    }, options)
    for (const select of [this.source, this.run]) {
      select.addEventListener("change", () => {
        if (select === this.source) this.run.value = ""
        if (select === this.run && this.run.value) this.source.value = "agent"
        this.signature = null
        this.needsFit = true
        this.refresh()
      }, options)
    }
    this.svg.addEventListener("wheel", event => {
      event.preventDefault()
      const rect = this.svg.getBoundingClientRect()
      this.zoom(Math.exp(-event.deltaY * 0.002), event.clientX - rect.left, event.clientY - rect.top)
    }, {...options, passive: false})
    this.svg.addEventListener("pointerdown", event => {
      if (event.button !== 0 || event.target.closest("[data-event]")) return
      this.drag = {x: event.clientX - this.transform.x, y: event.clientY - this.transform.y}
      this.setFollow(false)
      this.svg.setPointerCapture(event.pointerId)
    }, options)
    this.svg.addEventListener("pointermove", event => {
      if (!this.drag) return
      this.transform.x = event.clientX - this.drag.x
      this.transform.y = event.clientY - this.drag.y
      this.paintTransform()
    }, options)
    this.svg.addEventListener("pointerup", () => { this.drag = null }, options)
    this.svg.addEventListener("pointercancel", () => { this.drag = null }, options)
    this.resize = new ResizeObserver(() => {
      if (this.needsFit) this.fit()
      if (this.follow) this.focusLatest()
    })
    this.resize.observe(this.svg)
    this.needsFit = true
    this.refresh()
    this.timer = setInterval(() => {
      if (this.live && !document.hidden) this.refresh()
    }, 2000)
  }

  async refresh() {
    this.request?.abort()
    this.request = new AbortController()
    const request = this.request
    const params = new URLSearchParams({source: this.source.value, run_id: this.run.value})
    try {
      const response = await fetch(`${this.el.dataset.endpoint}?${params}`, {signal: request.signal, cache: "no-store"})
      if (!response.ok) throw new Error("Activity unavailable")
      const data = await response.json()
      if (request.signal.aborted) return
      this.status(data.truncated ? `Latest ${data.limit} actions` : "Up to date")
      this.updateRuns(data.runs || [])
      const signature = data.events.map(event => event.id).join(",")
      if (signature === this.signature) return
      this.signature = signature
      const wasEmpty = this.events.length === 0
      this.events = data.events
      this.graph = layoutActivity(this.events)
      this.render()
      if (wasEmpty || this.needsFit) this.fit()
      if (this.follow && this.events.length) this.focusLatest()
    } catch (error) {
      if (error.name !== "AbortError") this.status("Connection lost · retrying", true)
    }
  }

  updateRuns(runs) {
    const selected = this.run.value
    this.run.replaceChildren(new Option("All runs", ""), ...runs.map(id => new Option(id, id)))
    if (selected && !runs.includes(selected)) this.run.add(new Option(selected, selected))
    this.run.value = selected
    this.run.disabled = this.source.value === "shared"
  }

  status(text, error = false) {
    const el = this.el.querySelector("[data-status]")
    el.textContent = this.live ? text : "View paused · recording continues"
    el.dataset.error = String(error)
  }

  render() {
    const fragment = document.createDocumentFragment()
    for (const edge of this.graph.edges) {
      fragment.append(svg("path", {d: edgePath(edge), class: `ic-activity-edge ${edge.kind}`,
        "marker-end": `url(#${this.el.id}-arrow)`}))
    }
    for (const heading of this.graph.headings) {
      fragment.append(svg("text", {x: heading.x, y: heading.y, class: "ic-activity-lane"}, short(heading.text, 70)))
    }
    for (const page of this.graph.pages) {
      const group = svg("g", {transform: `translate(${page.x},${page.y})`, class: "ic-activity-page"})
      group.append(svg("rect", {width: 198, height: 64, rx: 8}),
        svg("text", {x: 14, y: 25, class: "host"}, short(page.host)),
        svg("text", {x: 14, y: 45, class: "path"}, short(page.path)),
        svg("title", {}, page.url || "No page address recorded"))
      fragment.append(group)
    }
    for (const node of this.graph.nodes) {
      const event = node.event
      const group = svg("g", {transform: `translate(${node.x},${node.y})`, tabindex: 0, role: "button",
        "data-event": event.id, "aria-label": `${actionLabel(event.action)} · ${event.outcome} · ${event.url || "Browser session"}`,
        class: `ic-activity-node${failed(event) ? " failed" : ""}`})
      group.append(svg("rect", {width: 198, height: 48, rx: 6}), svg("circle", {cx: 15, cy: 24, r: 3}),
        svg("text", {x: 27, y: 22, class: "action"}, short(actionLabel(event.action), 22)),
        svg("text", {x: 27, y: 37, class: "outcome"}, event.outcome.replaceAll("_", " ")))
      fragment.append(group)
    }
    this.scene.replaceChildren(fragment)
    this.el.querySelector("[data-count]").textContent = String(this.events.length)
    const empty = this.el.querySelector("[data-empty]")
    empty.hidden = this.events.length > 0
    empty.querySelector("h3").textContent = this.source.value || this.run.value ? "No actions in this view yet." : "The next move starts here."
    this.select(!this.follow && this.events.some(event => event.id === this.selected) ? this.selected : this.events.at(-1)?.id)
    this.paintTransform()
  }

  select(id) {
    this.selected = id
    for (const node of this.scene.querySelectorAll("[data-event]")) {
      const selected = Number(node.dataset.event) === id
      node.classList.toggle("selected", selected)
      node.setAttribute("aria-pressed", String(selected))
    }
    const event = this.events.find(event => event.id === id)
    const inspector = this.el.querySelector("[data-inspector]")
    inspector.replaceChildren()
    const line = (tag, text, className = "") => {
      const element = document.createElement(tag)
      element.className = className
      element.textContent = text
      inspector.append(element)
    }
    if (!event) {
      line("p", "INSPECT A STEP", "ic-activity-eyebrow")
      line("p", "Select an action to see its page, outcome, and time.")
      return
    }
    line("p", `${actionLabel(event.action)} · ${event.outcome.replaceAll("_", " ")}`, "ic-activity-detail-title")
    line("p", event.url || "No page address recorded", "ic-activity-detail-url")
    const duration = event.duration_ms == null ? "" : ` · ${event.duration_ms.toLocaleString()} ms`
    const source = event.source === "agent" ? `Agent Mode · ${event.run_id}` : "Shared browser"
    line("p", `${source} · ${new Date(event.inserted_at).toLocaleString()}${duration}`, "ic-activity-detail-meta")
  }

  click(event) {
    const node = event.target.closest("[data-event]")
    if (node) { this.setFollow(false); return this.select(Number(node.dataset.event)) }
    const action = event.target.closest("[data-action]")?.dataset.action
    if (action === "fit") { this.setFollow(false); this.fit() }
    if (action === "zoom-in") this.zoom(1.25)
    if (action === "zoom-out") this.zoom(0.8)
    if (action === "follow") {
      this.setFollow(!this.follow)
      if (this.follow) this.focusLatest()
    }
    if (action === "live") {
      this.live = !this.live
      this.el.querySelector('[data-action="live"]').setAttribute("aria-pressed", String(this.live))
      this.el.querySelector("[data-live-label]").textContent = this.live ? "Live" : "Paused"
      if (this.live) this.refresh()
      else { this.request?.abort(); this.status("") }
    }
  }

  fit() {
    const {width, height} = this.svg.getBoundingClientRect()
    if (!width || !height) return
    this.transform = fitTransform(this.graph, width, height)
    this.needsFit = false
    this.paintTransform()
  }

  zoom(factor, x = this.svg.clientWidth / 2, y = this.svg.clientHeight / 2) {
    this.setFollow(false)
    const t = this.transform
    const scale = Math.max(0.08, Math.min(3, t.scale * factor))
    const ratio = scale / t.scale
    this.transform = {scale, x: x - (x - t.x) * ratio, y: y - (y - t.y) * ratio}
    this.paintTransform()
  }

  setFollow(value) {
    this.follow = value
    this.el.querySelector('[data-action="follow"]').setAttribute("aria-pressed", String(value))
  }

  focusLatest() {
    const node = this.graph.nodes.find(node => node.event.id === this.events.at(-1)?.id)
    if (!node) return
    const scale = Math.max(0.75, this.transform.scale)
    this.transform = {scale, x: this.svg.clientWidth / 2 - (node.x + 99) * scale,
      y: this.svg.clientHeight / 2 - (node.y + 24) * scale}
    this.select(node.event.id)
    this.paintTransform()
  }

  paintTransform() {
    const {x, y, scale} = this.transform
    this.scene.setAttribute("transform", `translate(${x},${y}) scale(${scale})`)
    this.el.querySelector("[data-zoom]").textContent = `${Math.round(scale * 100)}%`
  }

  destroy() {
    clearInterval(this.timer)
    this.request?.abort()
    this.abort.abort()
    this.resize.disconnect()
  }
}
