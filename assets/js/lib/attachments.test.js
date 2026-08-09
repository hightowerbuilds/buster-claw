import {expect, test, describe} from "bun:test"
import {
  MAX_BYTES,
  MAX_FILES,
  basename,
  classify,
  describeRefusal,
  extensionOf,
  formatBytes,
  inspectFile,
  inspectFiles,
  inspectPaths,
  mediaTypeFor,
  safeFilename,
} from "./attachments.js"

// A dropped file as the DOM presents it: a name, whatever type the browser felt
// like declaring, and a size. Nothing here is a real `File` — that is the point
// of keeping the judgements out of the hook.
const file = (name, type = "", size = 1024) => ({name, type, size})

describe("classify — by extension", () => {
  test("the four inline-capable image types are images", () => {
    for (const name of ["a.png", "a.jpg", "a.jpeg", "a.gif", "a.webp", "A.PNG"]) {
      expect(classify(name)).toBe("image")
    }
  })

  test("prose, data and source code are all text", () => {
    for (const name of ["notes.md", "data.csv", "a.json", "mix.exs", "app.ts", "q.sql"]) {
      expect(classify(name)).toBe("text")
    }
  })

  test("files whose whole name is the type are text too", () => {
    expect(classify("Dockerfile")).toBe("text")
    expect(classify("Makefile")).toBe("text")
    expect(classify(".gitignore")).toBe("text")
  })

  test("pdf and unknown extensions are binary, not refusals", () => {
    // The roadmap's third row: a staged path carries anything, so there is
    // nothing to refuse here.
    expect(classify("report.pdf")).toBe("binary")
    expect(classify("archive.zip")).toBe("binary")
    expect(classify("thing.wat")).toBe("binary")
  })

  test("an image type no backend inlines is binary rather than refused", () => {
    // HEIC is what every iPhone photo actually is. It is a real file and a
    // staged path delivers it; it just never becomes an inline image block.
    expect(classify("IMG_0001.heic")).toBe("binary")
  })

  test("macOS bundles and installers are refused — they are not files we can carry", () => {
    for (const name of ["Xcode.app", "Thing.bundle", "My.xcodeproj", "Installer.dmg", "setup.exe"]) {
      expect(classify(name)).toBe(null)
    }
  })

  test("svg is text, never an image, so nothing downstream renders it", () => {
    expect(classify("drawing.svg", "image/svg+xml")).toBe("text")
    expect(mediaTypeFor("drawing.svg", "image/svg+xml")).toBe("text/plain")
  })
})

describe("classify — by media type", () => {
  test("a clipboard image has no useful name and is classified by its type", () => {
    // Exactly the ⌘V case: pasted screenshots arrive named "image.png" at best
    // and unnamed at worst.
    expect(classify("clipboard", "image/png")).toBe("image")
    expect(classify("", "image/jpeg")).toBe("image")
  })

  test("text and structured-text media types are text", () => {
    expect(classify("blob", "text/csv")).toBe("text")
    expect(classify("blob", "application/json")).toBe("text")
    expect(classify("blob", "application/vnd.api+json")).toBe("text")
    expect(classify("blob", "text/plain; charset=utf-8")).toBe("text")
  })

  test("anything else declared is binary", () => {
    expect(classify("blob", "application/zip")).toBe("binary")
    expect(classify("blob", "application/octet-stream")).toBe("binary")
    expect(classify("blob", "")).toBe("binary")
  })

  test("the extension outranks a wrong declared type", () => {
    // Browsers routinely declare `.ts` as video/mp2t and source files as
    // octet-stream. Believing them would stage text files for no reason.
    expect(classify("notes.md", "application/octet-stream")).toBe("text")
    expect(classify("app.ts", "video/mp2t")).toBe("text")
    expect(classify("shot.png", "application/octet-stream")).toBe("image")
  })

  test("media type is reported from the extension when we know it", () => {
    expect(mediaTypeFor("a.jpg")).toBe("image/jpeg")
    expect(mediaTypeFor("a.pdf")).toBe("application/pdf")
    expect(mediaTypeFor("mix.exs")).toBe("text/plain")
    expect(mediaTypeFor("clipboard", "image/png")).toBe("image/png")
    expect(mediaTypeFor("mystery")).toBe("application/octet-stream")
  })
})

describe("the size cap", () => {
  test("a file at the cap is fine and a file over it is refused at the drop", () => {
    expect(inspectFile(file("a.png", "image/png", MAX_BYTES)).ok).toBe(true)

    const over = inspectFile(file("a.png", "image/png", MAX_BYTES + 1))
    expect(over.ok).toBe(false)
    expect(over.reason).toBe("too_large")
    expect(over.filename).toBe("a.png")
  })

  test("the surface can publish its own cap", () => {
    expect(inspectFile(file("a.png", "image/png", 2048), {maxBytes: 1024}).reason).toBe("too_large")
    expect(inspectFile(file("a.png", "image/png", 2048), {maxBytes: 4096}).ok).toBe(true)
  })

  test("an unusable cap falls back to the default instead of refusing everything", () => {
    // `data-max-bytes` absent from the DOM arrives as NaN.
    expect(inspectFile(file("a.png", "image/png", 2048), {maxBytes: NaN}).ok).toBe(true)
    expect(inspectFile(file("a.png", "image/png", 2048), {maxBytes: 0}).ok).toBe(true)
  })

  test("a zero-byte file — or a dropped folder — is refused", () => {
    const seen = inspectFile(file("stuff", "", 0))
    expect(seen.ok).toBe(false)
    expect(seen.reason).toBe("empty")
  })

  test("a native path has no size, so no size verdict is claimed", () => {
    // The server size-checks before it reads. Passing here must not read as
    // "this file is within the cap" — it reads as "we never saw a size".
    const seen = inspectFile({name: "/Users/x/huge.png", type: "", size: null})
    expect(seen.ok).toBe(true)
    expect(seen.bytes).toBe(null)
  })
})

describe("the count cap", () => {
  test("files past the cap are refused individually, not as a silent truncation", () => {
    const many = Array.from({length: MAX_FILES + 2}, (_, i) => file(`${i}.png`, "image/png"))
    const {accepted, rejected} = inspectFiles(many)

    expect(accepted).toHaveLength(MAX_FILES)
    expect(rejected).toHaveLength(2)
    expect(rejected[0].reason).toBe("too_many")
    expect(rejected[0].filename).toBe(`${MAX_FILES}.png`)
  })

  test("the cap counts what is already staged, not just this gesture", () => {
    const {accepted, rejected} = inspectFiles([file("a.png"), file("b.png")], {
      maxFiles: 3,
      existing: 2,
    })

    expect(accepted.map((a) => a.filename)).toEqual(["a.png"])
    expect(rejected.map((r) => r.reason)).toEqual(["too_many"])
  })
})

describe("filenames", () => {
  test("traversal is cleaned away — a name is only ever its last segment", () => {
    expect(safeFilename("../../etc/passwd")).toBe("passwd")
    expect(safeFilename("/Users/x/Desktop/shot.png")).toBe("shot.png")
    expect(safeFilename("C:\\Users\\x\\evil.png")).toBe("evil.png")
    expect(safeFilename("a/../b.md")).toBe("b.md")
  })

  test("NUL and other control bytes are stripped", () => {
    expect(safeFilename("sh\u0000ot.png")).toBe("shot.png")
    expect(safeFilename("re\u001bport.pdf")).toBe("report.pdf")
    expect(safeFilename("tab\tname.txt")).toBe("tabname.txt")
  })

  test("runs of whitespace collapse and the ends are trimmed", () => {
    expect(safeFilename("  my    shot.png  ")).toBe("my shot.png")
  })

  test("a name with nothing left in it is rejected outright", () => {
    expect(safeFilename("..")).toBe(null)
    expect(safeFilename(".")).toBe(null)
    expect(safeFilename("")).toBe(null)
    expect(safeFilename("   ")).toBe(null)
    expect(safeFilename("\u0000")).toBe(null)
    expect(safeFilename(null)).toBe(null)
    expect(safeFilename(undefined)).toBe(null)
  })

  test("an absurd name is clipped but keeps its extension", () => {
    const long = safeFilename(`${"x".repeat(4000)}.png`)
    expect(long.length).toBeLessThanOrEqual(200)
    expect(long.endsWith(".png")).toBe(true)
  })

  test("a file whose name cannot be cleaned is a refusal, not a rename", () => {
    const seen = inspectFile(file("..", "image/png"))
    expect(seen.ok).toBe(false)
    expect(seen.reason).toBe("bad_filename")
  })

  test("the accepted verdict carries the cleaned name", () => {
    const seen = inspectFile(file("../../shot.png", "image/png"))
    expect(seen).toMatchObject({ok: true, filename: "shot.png", kind: "image"})
  })
})

describe("a whole drop", () => {
  test("an empty list is a no-op, not an error", () => {
    expect(inspectFiles([])).toEqual({accepted: [], rejected: []})
    expect(inspectPaths([])).toEqual({accepted: [], rejected: []})
    expect(inspectFiles(null)).toEqual({accepted: [], rejected: []})
    expect(inspectPaths(undefined)).toEqual({accepted: [], rejected: []})
    expect(inspectPaths(["", "   "])).toEqual({accepted: [], rejected: []})
  })

  test("the good files still go through when one of them is refused", () => {
    const {accepted, rejected} = inspectFiles([
      file("ok.png", "image/png"),
      file("huge.png", "image/png", MAX_BYTES * 2),
      file("notes.md", "text/markdown"),
    ])

    expect(accepted.map((a) => a.filename)).toEqual(["ok.png", "notes.md"])
    expect(rejected.map((r) => r.reason)).toEqual(["too_large"])
  })

  test("accepted files carry the index of the File they came from", () => {
    // The hook maps this back to the real `File` objects; getting it wrong
    // would upload the wrong file under the right name.
    const {accepted} = inspectFiles([file("Xcode.app"), file("ok.png", "image/png")])
    expect(accepted).toHaveLength(1)
    expect(accepted[0].index).toBe(1)
  })
})

describe("native paths", () => {
  test("the path is passed through untouched while the display name is cleaned", () => {
    const {accepted} = inspectPaths(["/Users/x/My Screenshots/shot 1.png"])

    expect(accepted[0].path).toBe("/Users/x/My Screenshots/shot 1.png")
    expect(accepted[0].filename).toBe("shot 1.png")
    expect(accepted[0].kind).toBe("image")
    expect(accepted[0].source).toBe("native_path")
  })

  test("a bundle dropped from Finder is refused before the server ever reads it", () => {
    const {accepted, rejected} = inspectPaths(["/Applications/Xcode.app"])

    expect(accepted).toEqual([])
    expect(rejected[0]).toMatchObject({reason: "unsupported_type", filename: "Xcode.app"})
  })

  test("kinds are decided from the extension, since a path declares no type", () => {
    const {accepted} = inspectPaths(["/a/b.pdf", "/a/notes.md", "/a/shot.png"])
    expect(accepted.map((a) => a.kind)).toEqual(["binary", "text", "image"])
  })
})

describe("refusal messages", () => {
  test("every reason produces a sentence that names the file", () => {
    for (const reason of [
      "too_large",
      "too_many",
      "empty",
      "unsupported_type",
      "bad_filename",
      "unavailable",
      "something_new",
    ]) {
      const message = describeRefusal({reason, filename: "shot.png"})
      expect(message).toContain("shot.png")
      expect(message.length).toBeGreaterThan(10)
    }
  })

  test("the size message quotes the cap that was actually applied", () => {
    expect(describeRefusal({reason: "too_large", filename: "a.png", maxBytes: 1024})).toContain(
      "1 KB"
    )
  })

  test("a refusal with no filename still reads as a sentence", () => {
    expect(describeRefusal({reason: "empty"})).toContain("That file")
    expect(describeRefusal(null)).toContain("That file")
  })
})

describe("formatBytes", () => {
  test("reads the way a person would say it", () => {
    expect(formatBytes(512)).toBe("512 B")
    expect(formatBytes(1536)).toBe("1.5 KB")
    expect(formatBytes(10 * 1024 * 1024)).toBe("10 MB")
    expect(formatBytes(NaN)).toBe("?")
  })
})

describe("name helpers", () => {
  test("basename and extensionOf agree on the awkward cases", () => {
    expect(basename("/a/b/c.txt")).toBe("c.txt")
    expect(basename("c.txt")).toBe("c.txt")
    expect(basename(null)).toBe("")
    expect(extensionOf("a.tar.gz")).toBe("gz")
    expect(extensionOf(".gitignore")).toBe("")
    expect(extensionOf("Makefile")).toBe("")
    expect(extensionOf("A.PNG")).toBe("png")
  })
})
