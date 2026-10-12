import {describe, expect, test} from "bun:test"
import {edgePath, fitTransform, layoutActivity, pageLabel} from "./browser_activity_model.js"

const event = (id, url, source = "shared", run_id = null) => ({id, url, source, run_id, action: "read", outcome: "ok"})

describe("browser activity graph", () => {
  test("groups actions under page visits and preserves revisits", () => {
    const graph = layoutActivity([
      event(1, "https://example.com/a"), event(2, "https://example.com/a"),
      event(3, "https://example.com/b"), event(4, "https://example.com/a"),
    ])
    expect(graph.pages.map(page => page.url)).toEqual([
      "https://example.com/a", "https://example.com/b", "https://example.com/a",
    ])
    expect(graph.nodes.map(node => node.event.id)).toEqual([1, 2, 3, 4])
    expect(graph.edges.filter(edge => edge.kind === "sequence")).toHaveLength(3)
    expect(graph.nodes[1].x).toBe(graph.nodes[0].x)
    expect(graph.nodes[2].x).toBeGreaterThan(graph.nodes[1].x)
  })

  test("does not connect actions across independent agent runs", () => {
    const graph = layoutActivity([
      event(1, null), event(2, null, "agent", "one"), event(3, null, "agent", "two"),
      event(4, null, "agent", "one"),
    ])
    expect(graph.headings).toHaveLength(3)
    expect(graph.edges.filter(edge => edge.kind === "sequence")).toHaveLength(1)
    expect(new Set(graph.nodes.map(node => `${node.x},${node.y}`)).size).toBe(4)
  })

  test("sorts receipts and draws explicit directed paths", () => {
    const graph = layoutActivity([event(2, "https://b.test"), event(1, "https://a.test")])
    expect(graph.nodes.map(node => node.event.id)).toEqual([1, 2])
    expect(graph.edges.every(edge => edgePath(edge).startsWith("M"))).toBe(true)
  })

  test("handles empty views and unknown page addresses", () => {
    const graph = layoutActivity([])
    expect(graph.nodes).toEqual([])
    expect(pageLabel(null).host).toBe("Browser session")
    const fit = fitTransform(graph, 800, 400)
    expect(fit.scale).toBeGreaterThan(0)
    expect(Number.isFinite(fit.x)).toBe(true)
  })
})
