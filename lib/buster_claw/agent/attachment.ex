defmodule BusterClaw.Agent.Attachment do
  @moduledoc """
  The shared shape of a chat attachment — a file dragged or pasted into the
  homepage chat. **Types and documentation only; no logic lives here.**

  It exists because four stages have to agree on what an attachment *is*: the
  browser hook that receives the drop, the store that stages the bytes, the
  backend layer that hands it to a CLI, and the transcript that renders it.

  ## The pipeline

      drop / paste
        └─ ChatDropzone hook       → bytes (HTML5) or a path (Tauri native)
        └─ Agent.Attachments.stage → t:t/0, bytes written to the staging dir
        └─ AgentBackend            → per-backend CLI arguments, or an inline block
        └─ ChatPanel               → a chip in the composer, a thumbnail in the bubble

  ## Staging is not saving, and the difference is the whole design

  The operator's constraint (08-08) was that the model must not be saving images
  into the workspace without being asked. So an attachment is written to an
  **app-managed staging directory that is not the workspace the agent browses**,
  and it **dies with its conversation** — the rule `chat_svgs` already
  established for model-drawn SVGs, applied unchanged.

  The app puts a file somewhere the agent can read it for one turn. The *model*
  never decides to keep anything. Keeping an attachment is a separate, explicit
  act.

  ## Why a file exists at all

  Measured in Phase 0, not assumed: **Codex takes `-i/--image <FILE>` and
  OpenCode takes `-f/--file`, and neither accepts bytes.** A file on disk is
  therefore required for two of the three backends no matter what the transport
  can carry. Claude's inline base64 block — which needs no file at all — is an
  optimisation available on one path of one backend, not an alternative
  architecture. **Stage once; deliver per backend.**

  ## The DOM is never trusted to have the bytes

  macOS WKWebView does not hand file *contents* to the DOM on an OS drop (see
  `assets/js/hooks/workspace_dropzone.js`, which solved this once already). In
  the packaged app the hook receives a **path** and the server reads it; in a dev
  browser it receives contents. `t:source/0` records which, because the two have
  genuinely different trust properties — a path from the OS names a file the user
  chose, and must still be checked before it is read.
  """

  @typedoc """
  How the bytes reached us, which decides what has to be validated.

  - `:upload` — an HTML5 upload through LiveView. The bytes are already in a
    temp file the framework owns; the *name* is attacker-influenced.
  - `:native_path` — a path from the Tauri drag-drop event. **The path is real
    and absolute and names a file anywhere on the machine**, so it is read on the
    user's behalf and must be size-checked before it is read, not after.
  """
  @type source :: :upload | :native_path

  @typedoc """
  What the attachment is, which decides how it is delivered.

  - `:image` — png, jpeg, gif, webp. Every backend has a native mechanism.
  - `:text` — markdown, plain text, csv, source code, json. **Delivered inline as
    text**, needing neither a file nor an image block. This is the common case
    for "other files" and the one that costs nothing.
  - `:binary` — pdf and everything else. Delivered as a path only; no CLI's
    document support has been verified here.
  """
  @type kind :: :image | :text | :binary

  @typedoc """
  One staged attachment.

  `id` is stable within its conversation so the composer can remove one before
  sending and the transcript can address it afterwards. `filename` is the name
  the user saw and is **display-only** — it is never used to build a path.
  `path` is where the app staged it, always inside the staging directory.

  `bytes` is the size on disk. It is carried rather than re-stat'd because the
  composer shows it before the turn runs and the cap is enforced at the drop,
  where a refusal is still cheap and visible.
  """
  @type t :: %{
          id: String.t(),
          conversation_id: String.t(),
          filename: String.t(),
          media_type: String.t(),
          kind: kind(),
          bytes: non_neg_integer(),
          path: String.t(),
          source: source()
        }

  @typedoc """
  What a backend needs in order to deliver an attachment — the short per-backend
  tail on the end of one shared pipeline.

  - `{:args, [String.t()]}` — extra CLI arguments (Codex's `-i`, OpenCode's
    `-f`, Claude's `--add-dir`).
  - `{:inline, map()}` — a content block to splice into the streaming JSON
    message. **Claude streaming only**, and the only route where no file need
    exist.
  - `{:prompt_prefix, String.t()}` — text prepended to the prompt, which is how
    a path is announced to a backend that reads files by path rather than
    attaching them.
  """
  @type delivery ::
          {:args, [String.t()]}
          | {:inline, map()}
          | {:prompt_prefix, String.t()}
end
