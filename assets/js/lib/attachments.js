// What the chat will accept as an attachment, decided at the drop — before a
// byte is uploaded and before a path is handed to the server.
//
// Pure on purpose. `hooks/chat_dropzone.js` owns the DOM and the two transports;
// this owns every judgement either transport has to make, so `bun test` can
// cover the refusals without a DOM, a LiveSocket, or a webview.
//
// **The two transports do not see the same evidence, and that shapes the API.**
//
//   HTML5 drop / paste   name + declared media type + size   every check below
//   Tauri native drop    an absolute PATH and nothing else   name checks only
//
// macOS WKWebView does not hand file *contents* to the DOM on an OS drop (see
// `hooks/workspace_dropzone.js`, which solved this once already), so in the
// packaged app all we ever have is a path. A path carries no size, so the cap
// **cannot** be enforced here for it — `BusterClaw.Agent.Attachment`'s
// `:native_path` source says the same thing from the other end: the file must be
// size-checked by the server before it is read. This module returns `bytes:
// null` there rather than inventing a number, and never reports a check it could
// not actually perform.
//
// The caps are the client's, and they are a courtesy: they exist so a refusal is
// visible immediately instead of arriving after an upload that looked like it
// worked. The server enforces its own, and the server's is the real one.

// 10 MB, and the number is a UI decision rather than a protocol limit: it is
// large enough for any screenshot or source file and small enough that a
// mis-drop of a video is refused instantly. Overridable per-surface via
// `data-max-bytes`, so the server can publish one number both ends agree on.
// (Images delivered through Claude's inline base64 block face a much stricter
// API-side limit; that belongs to whoever encodes them, not to the drop.)
export const MAX_BYTES = 10 * 1024 * 1024
export const MAX_FILES = 5

// The four image types every backend has a native mechanism for, per
// `Attachment`'s `t:kind/0`. Anything else that is an image — HEIC being the
// obvious one on this platform — is still a real file, so it falls through to
// `binary` and travels as a staged path. It is not refused; it just does not
// get the inline treatment.
const IMAGE_MEDIA = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
}

const INLINE_IMAGE_MEDIA = new Set(Object.values(IMAGE_MEDIA))

// Text-ish by extension, because the browser's declared type is unreliable for
// exactly the files a developer drops: `.ex`, `.exs`, `.toml` and friends all
// arrive as `""` or `application/octet-stream`. Getting this right is worth the
// list — a text attachment is inlined as text and costs nothing, while the same
// file misread as a binary becomes a staged file for no reason.
const TEXT_EXTENSIONS = new Set(
  (
    "txt md markdown rst tex csv tsv json jsonc yaml yml toml ini cfg conf log " +
    "xml html htm svg css scss sass less js jsx mjs cjs ts tsx vue " +
    "ex exs eex heex erl hrl rs go py rb java kt kts c h cc cpp hpp cs swift m mm " +
    "sh bash zsh fish ps1 sql r lua php pl pm dart scala clj cljs hs ml vim " +
    "diff patch env srt vtt gql graphql proto"
  ).split(" ")
)

// Files whose whole name IS the type. `.gitignore` and `Dockerfile` have no
// extension to look at, and treating them as unknown binaries would be wrong in
// the most common direction.
const BARE_TEXT_NAMES = new Set([
  "makefile",
  "dockerfile",
  "procfile",
  "gemfile",
  "rakefile",
  "justfile",
  "readme",
  "license",
  "changelog",
  ".gitignore",
  ".gitattributes",
  ".env",
  ".dockerignore",
  ".formatter.exs",
])

// The only refusal by type, and every entry earns its place.
//
// The bundles are **directories wearing a file's clothes** — macOS hands
// `/Applications/Foo.app` to a drop as a single path, and neither transport can
// carry a directory: the HTML5 side has no bytes for it and the native side
// would have the server walking a tree it never asked for. The executables are
// refused because there is nothing for a model to read in them, and staging one
// is all cost.
//
// Everything else binary — pdf, zip, a font, an unknown extension — is accepted
// and travels as a staged path, which is what the roadmap's third row says.
const UNSUPPORTED_EXTENSIONS = new Set([
  "app",
  "bundle",
  "framework",
  "xcodeproj",
  "xcworkspace",
  "photoslibrary",
  "fcpbundle",
  "rtfd",
  "download",
  "dmg",
  "pkg",
  "mpkg",
  "msi",
  "exe",
  "dylib",
  "so",
])

// The last path segment, for POSIX and Windows separators both. This is the
// first line of defence and the reason traversal never reaches a filename:
// `../../etc/passwd` is `passwd` before anything else looks at it.
export function basename(pathOrName) {
  const s = String(pathOrName == null ? "" : pathOrName)
  const cut = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"))
  return cut === -1 ? s : s.slice(cut + 1)
}

// Lowercased extension, or "" when there isn't one. A leading dot is a dotfile,
// not an extension — `.gitignore` has no extension and is matched by name.
export function extensionOf(name) {
  const base = basename(name).toLowerCase()
  const dot = base.lastIndexOf(".")
  if (dot <= 0) return ""
  return base.slice(dot + 1)
}

// A name safe to *display*, or null when nothing usable survives.
//
// `Attachment`'s contract is that the filename is display-only and is never used
// to build a path, so this is not the thing standing between us and a traversal
// — the server not concatenating it is. It is still cleaned here because the
// name is attacker-influenced on the upload path, it goes straight into the
// composer chip and into an `attach_error` message, and a control byte or a
// 4 KB name in either place is a defect on its own.
export function safeFilename(raw) {
  const name = basename(raw)
    // NUL and the rest of C0/DEL. NUL first among equals: it truncates strings
    // in every language downstream of here that isn't Elixir.
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/\s+/g, " ")
    .trim()

  if (name === "" || name === "." || name === "..") return null

  return name.length > MAX_NAME_LENGTH ? clipName(name) : name
}

const MAX_NAME_LENGTH = 200

// Clip the stem, keep the extension: the extension is what tells a reader (and
// the classifier) what the thing is, so it is the last part to lose.
function clipName(name) {
  const ext = extensionOf(name)
  if (!ext) return name.slice(0, MAX_NAME_LENGTH)
  const stem = name.slice(0, name.length - ext.length - 1)
  return `${stem.slice(0, Math.max(1, MAX_NAME_LENGTH - ext.length - 1))}.${ext}`
}

// The media type we will report, preferring the extension over what the browser
// declared. The extension wins because it is the more reliable of the two for
// the files people actually drop here, and because a native-path drop has no
// declared type at all — one rule for both transports rather than two.
export function mediaTypeFor(name, declared = "") {
  const ext = extensionOf(name)
  if (IMAGE_MEDIA[ext]) return IMAGE_MEDIA[ext]
  if (ext === "pdf") return "application/pdf"

  // SVG is markup, not a picture, and this codebase has already paid once for
  // treating it as one (the SVG XSS in the 07-04 review). It is deliberately
  // reported as text so that nothing downstream sees `image/*` and decides a
  // thumbnail — the browser would happily run the script inside it. The
  // *declared* type is overruled here for the same reason.
  if (ext === "svg") return "text/plain"

  const given = normalizeMedia(declared)
  if (given && given !== "application/octet-stream") return given

  if (textishByName(name)) return "text/plain"
  return "application/octet-stream"
}

// `image` | `text` | `binary` per `Attachment`'s `t:kind/0`, or **null** for
// "refuse this, it is not an attachment."
export function classify(name, declared = "") {
  if (UNSUPPORTED_EXTENSIONS.has(extensionOf(name))) return null
  if (IMAGE_MEDIA[extensionOf(name)]) return "image"
  if (textishByName(name) || textishByMedia(declared)) return "text"

  const media = mediaTypeFor(name, declared)
  if (INLINE_IMAGE_MEDIA.has(media)) return "image"
  return "binary"
}

function normalizeMedia(declared) {
  return String(declared || "")
    .split(";")[0]
    .trim()
    .toLowerCase()
}

function textishByName(name) {
  const ext = extensionOf(name)
  if (ext) return TEXT_EXTENSIONS.has(ext)
  return BARE_TEXT_NAMES.has(basename(name).toLowerCase())
}

function textishByMedia(declared) {
  const media = normalizeMedia(declared)
  if (!media) return false
  if (media.startsWith("text/")) return true
  if (media === "application/json" || media === "application/xml") return true
  return /\+(json|xml)$/.test(media)
}

// One file's verdict. Takes plain facts — `{name, type, size}` — rather than a
// `File`, so the caller can pass a DOM File, a clipboard item, or a bare path
// and this module never learns what a DOM is.
//
// `size` may be null (a native-path drop), and then the size cap simply is not
// applied: reporting a pass would claim a check that never ran.
export function inspectFile(file, opts = {}) {
  const maxBytes = positive(opts.maxBytes, MAX_BYTES)
  const filename = safeFilename(file && file.name)
  if (!filename) return refusal("bad_filename", basename(file && file.name) || "(unnamed)")

  const kind = classify(filename, file && file.type)
  if (!kind) return refusal("unsupported_type", filename)

  const bytes = Number.isFinite(file && file.size) ? file.size : null
  // A dropped folder arrives on the HTML5 path as a zero-byte File, so this
  // catches both "genuinely empty" and "that was a directory" — the message
  // says both, because we cannot tell them apart from here.
  if (bytes === 0) return refusal("empty", filename)
  if (bytes !== null && bytes > maxBytes) return refusal("too_large", filename, {maxBytes})

  return {ok: true, filename, kind, mediaType: mediaTypeFor(filename, file && file.type), bytes}
}

// A whole drop or paste: `{accepted, rejected}`, both always arrays.
//
// Accepted entries carry their `index` in the input list, which is how the hook
// maps a verdict back to the `File` object it must hand to LiveView without this
// module ever touching one.
//
// `opts.existing` is how many are already staged, so the count cap is against
// the conversation rather than against this one gesture — dropping three files
// twice must not sneak past a cap of five.
export function inspectFiles(files, opts = {}) {
  const list = Array.isArray(files) ? files : []
  const maxFiles = positive(opts.maxFiles, MAX_FILES)
  let room = Math.max(0, maxFiles - positive(opts.existing, 0, 0))

  const accepted = []
  const rejected = []

  list.forEach((file, index) => {
    const seen = inspectFile(file, opts)
    if (!seen.ok) {
      rejected.push(seen)
      return
    }
    if (room === 0) {
      rejected.push(refusal("too_many", seen.filename, {maxFiles}))
      return
    }
    room -= 1
    accepted.push({...seen, index, source: "upload"})
  })

  return {accepted, rejected}
}

// The Tauri side: absolute paths, no sizes.
//
// The **path is passed through byte-for-byte** — it is the server's only handle
// on the file and cleaning it would break the read. Only the display name is
// cleaned, which is why `filename` and `path` are separate fields here rather
// than one string doing two jobs.
export function inspectPaths(paths, opts = {}) {
  const list = (Array.isArray(paths) ? paths : []).filter(
    (p) => typeof p === "string" && p.trim() !== ""
  )

  const {accepted, rejected} = inspectFiles(
    list.map((p) => ({name: p, type: "", size: null})),
    opts
  )

  return {
    accepted: accepted.map((a) => ({...a, path: list[a.index], source: "native_path"})),
    rejected,
  }
}

// The sentence the user reads. It always names the file, because "that file was
// rejected" in a chat where four things were just dropped is not a message.
export function describeRefusal(r) {
  const name = (r && r.filename) || "That file"

  switch (r && r.reason) {
    case "too_large":
      return `${name} is bigger than the ${formatBytes(positive(r.maxBytes, MAX_BYTES))} limit.`
    case "too_many":
      return `${name} wasn't attached — ${positive(r.maxFiles, MAX_FILES)} files at a time is the limit.`
    case "empty":
      return `${name} is empty, or is a folder — there's nothing to attach.`
    case "unsupported_type":
      return `${name} isn't a kind of file the chat can attach.`
    case "bad_filename":
      return `${name} has a name that can't be used.`
    case "unavailable":
      return `${name} can't be attached here yet.`
    default:
      return `${name} couldn't be attached.`
  }
}

export function formatBytes(n) {
  if (!Number.isFinite(n) || n < 0) return "?"
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${round(n / 1024)} KB`
  return `${round(n / (1024 * 1024))} MB`
}

function round(n) {
  return n >= 10 ? Math.round(n) : Math.round(n * 10) / 10
}

function refusal(reason, filename, extra = {}) {
  return {ok: false, reason, filename, ...extra}
}

// A caller-supplied cap only replaces the default when it is a usable number —
// `data-max-bytes` missing from the DOM arrives as `NaN`, and a NaN cap silently
// refuses everything.
function positive(value, fallback, floor = 1) {
  const n = Number(value)
  return Number.isFinite(n) && n >= floor ? n : fallback
}
