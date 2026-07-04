import {describe, expect, test} from "bun:test"
import {layoutGraph, MAX_NODES, MAX_LABEL} from "./diagram_layout.js"

const DIMS = {width: 1024, height: 512}

describe("layoutGraph (the diagram trust boundary + layout)", () => {
  test("empty / non-object spec yields an empty layout", () => {
    expect(layoutGraph(null, DIMS)).toEqual({width: 1024, height: 512, nodes: [], edges: []})
    expect(layoutGraph({}, DIMS).nodes).toEqual([])
    expect(layoutGraph({nodes: "nope"}, DIMS).nodes).toEqual([])
  })

  test("lays a->b->c out left to right by dependency depth", () => {
    const {nodes} = layoutGraph(
      {nodes: [{id: "a"}, {id: "b"}, {id: "c"}], edges: [["a", "b"], ["b", "c"]]},
      DIMS
    )
    const cx = Object.fromEntries(nodes.map((n) => [n.id, n.cx]))
    expect(cx.a).toBeLessThan(cx.b)
    expect(cx.b).toBeLessThan(cx.c)
    // Labels default to the id; all boxes sit within the surface.
    for (const n of nodes) {
      expect(n.label).toBe(n.id)
      expect(n.cx).toBeGreaterThanOrEqual(0)
      expect(n.cx).toBeLessThanOrEqual(DIMS.width)
      expect(n.cy).toBeGreaterThan(0)
      expect(n.cy).toBeLessThan(DIMS.height)
    }
  })

  test("caps node count and dedupes / drops bad ids", () => {
    const many = Array.from({length: MAX_NODES + 10}, (_, i) => ({id: "n" + i}))
    expect(layoutGraph({nodes: many}, DIMS).nodes.length).toBe(MAX_NODES)

    const {nodes} = layoutGraph(
      {nodes: [{id: "a"}, {id: "a"}, {label: "no id"}, {id: "b"}]},
      DIMS
    )
    expect(nodes.map((n) => n.id)).toEqual(["a", "b"])
  })

  test("truncates long labels", () => {
    const long = "x".repeat(MAX_LABEL + 20)
    const {nodes} = layoutGraph({nodes: [{id: "a", label: long}]}, DIMS)
    expect(nodes[0].label.length).toBe(MAX_LABEL)
    expect(nodes[0].label.endsWith("…")).toBe(true)
  })

  test("drops edges to unknown nodes; accepts array and object edge forms", () => {
    const {edges} = layoutGraph(
      {
        nodes: [{id: "a"}, {id: "b"}],
        edges: [["a", "b"], ["a", "ghost"], {from: "b", to: "a"}, ["x", "y"]],
      },
      DIMS
    )
    expect(edges.length).toBe(2) // a->b and b->a; the two dangling ones dropped
  })

  test("a cycle is handled without hanging and stays in bounds", () => {
    const {nodes} = layoutGraph(
      {nodes: [{id: "a"}, {id: "b"}], edges: [["a", "b"], ["b", "a"]]},
      DIMS
    )
    expect(nodes.length).toBe(2)
    for (const n of nodes) expect(n.cx).toBeLessThanOrEqual(DIMS.width)
  })
})
