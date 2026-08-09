defmodule BusterClaw.Agent.AttachmentDelivery do
  @moduledoc """
  Hand a staged attachment to whichever agent CLI is running.

  `BusterClaw.AgentBackend` owns the *flag vocabulary* — which letter each CLI
  spells an attached file with. This module owns everything above that: reading
  the staged file, deciding whether a given attachment travels as bytes, as a
  path, or as text spliced into the prompt, and assembling the
  `t:BusterClaw.Agent.Attachment.delivery/0` values a call site hands to the port.

  ## Why this is not in `AgentBackend`

  **Every function here reads from disk.** `AgentBackend` is a pure table —
  `argv/3` is string concatenation, `attachment_args/2` is a `flat_map`, and
  `installed/0` is called straight from a LiveView mount. The one function there
  that shells out (`enumerate_models/1`) carries a shouted warning saying so,
  precisely because everything around it is free. Putting `File.read/1` and
  `Base.encode64/1` behind that module's flat surface would break the property
  that warning depends on.

  So: measured per-CLI flags there, I/O and policy here. The delivery type itself
  lives with `Agent.Attachment`, alongside the rest of the pipeline's shapes.

  ## The per-backend mapping — measured 08-08-26, not recalled

  Same method as every other flag in `AgentBackend`: `--help` against the
  installed binary, plus the Phase 0 probe of an actual image (a 120×120 PNG,
  magenta ground and yellow square — both facts verifiable, neither guessable).

  | Backend | Images | Text | PDF and other binaries |
  |---|---|---|---|
  | **claude**, streaming | inline base64 block. **No file is involved at all** | inline text block | `--add-dir` + path named in the prompt |
  | **claude**, default (`-p`) | `--add-dir` + path named in the prompt | inlined into the prompt | same |
  | **codex** | `-i <path>` per image | inlined into the prompt | **path named in the prompt — never `-i`** |
  | **opencode** | `-f <path>` | inlined into the prompt | `-f <path>` |
  | anything else | path named in the prompt | inlined into the prompt | path named in the prompt |

  Evidence, so the next reader does not re-derive it:

    * `claude` — has **no attachment flag whatsoever**. Its two routes were both
      verified end to end: the inline block on `--input-format stream-json` was
      answered correctly *with no file on disk and no Read tool call*, and the
      `-p` + `--add-dir` route was answered correctly by reading the path.
    * `codex exec --help` → `-i, --image <FILE>...  Optional image(s) to attach
      to the initial prompt`.
    * `opencode run --help` → `-f, --file  file(s) to attach to message [array]`.

  ## Why codex's non-images do NOT get `-i`

  The asymmetry that decides this is one word in the two help strings: codex says
  **image(s)**, opencode says **file(s)**. `-i` names a flag codex will hand to an
  image decoder, so a PDF passed through it is a decode failure — and a decode
  failure fails the *run*, not the attachment. Refusing to attach one file must
  never cost the operator their turn.

  So a non-image on codex is announced by absolute path in the prompt prefix and
  left to codex's own file tools. **Unverified:** whether codex's sandbox
  (`-s read-only` / `-s workspace-write`) can read the staging directory, which
  lives outside the working root. `workspace-write` is documented as a *write*
  restriction, so a read is expected to work — expected, not measured.

  ## Text is inlined everywhere, and that is the cheap path

  A text attachment needs no flag, no file grant, and no per-backend anything: its
  contents go into the prompt. It is the common case for "other files" and the one
  that costs nothing.

  The cap is `max_inline_text_bytes/0` (64 KiB). **Over the cap the attachment is
  not truncated — it degrades to path delivery**, exactly like a PDF. Truncation
  would hand the model a partial file with no marker saying so, which is the one
  failure mode worse than not inlining: silently wrong beats loudly absent every
  time. The same degrade covers an unreadable file and one that is not valid
  UTF-8 (which would raise inside `Jason.encode!/1` on the streaming path).

  ## Attachment contents are untrusted text

  An inlined file is operator-supplied text landing inside the prompt, so it can
  say anything — including things shaped like instructions. The BEGIN/END markers
  below are a legibility aid, not a security boundary; nothing here can make file
  contents safe to obey. That is inherent to the feature and is the same exposure
  the agent already has when it reads a file itself.
  """

  alias BusterClaw.Agent.Attachment
  alias BusterClaw.AgentBackend

  # 64 KiB of text is a very large pasted file and a small fraction of the
  # encoder's 512 KiB line budget, so an inlined attachment cannot on its own
  # push a message over the wire limit.
  @max_inline_text_bytes 64 * 1024

  @doc """
  The ceiling on a text attachment inlined into the prompt.

  Over this, the attachment is delivered as a path instead — see the moduledoc on
  why it is never truncated.
  """
  @spec max_inline_text_bytes() :: pos_integer()
  def max_inline_text_bytes, do: @max_inline_text_bytes

  @doc """
  The `t:BusterClaw.Agent.Attachment.delivery/0` values `backend` needs in order
  to see `attachments`.

  Options:

    * `:duplex` — `true` when the run is on claude's streaming-input path
      (`--input-format stream-json`). That is the only route where an inline block
      is possible, and it is deliberately the same option key `argv/3` and
      `stream_args/2` already use, so a call site cannot enable one and forget the
      other.

  **An empty list returns `[]`.** That is the property the whole feature rests on:
  a turn with no attachments produces byte-identical argv, an unchanged JSONL
  line, and an untouched prompt.

  Deliveries come back in the order a caller wants to apply them: directory
  grants, then attachment flags, then inline blocks, then a single prompt prefix.
  """
  @spec deliveries(atom(), [Attachment.t()], keyword()) :: [Attachment.delivery()]
  def deliveries(backend, attachments, opts \\ [])

  def deliveries(_backend, [], _opts), do: []

  def deliveries(backend, attachments, opts) when is_list(attachments) do
    mode = if AgentBackend.inline_attachments?(backend, opts), do: :inline, else: :flags

    attachments
    |> Enum.map(&prepare(&1, mode))
    |> emit(backend)
  end

  @doc """
  The extra CLI arguments in `deliveries`, flattened in order.

  Append to `:extra_args`; `[]` when nothing needs a flag.
  """
  @spec args([Attachment.delivery()]) :: [String.t()]
  def args(deliveries) when is_list(deliveries) do
    Enum.flat_map(deliveries, fn
      {:args, args} -> args
      _other -> []
    end)
  end

  @doc """
  The inline content blocks in `deliveries`, in order.

  Pass to `BusterClaw.Agent.ChatMessageEncoder.encode_user/2`. Always `[]` off
  claude's streaming path, which is what makes that encoder call a no-op
  everywhere else.
  """
  @spec blocks([Attachment.delivery()]) :: [map()]
  def blocks(deliveries) when is_list(deliveries) do
    for {:inline, block} <- deliveries, do: block
  end

  @doc """
  The text to prepend to the prompt, or `""` when there is none.
  """
  @spec prompt_prefix([Attachment.delivery()]) :: String.t()
  def prompt_prefix(deliveries) when is_list(deliveries) do
    deliveries
    |> Enum.flat_map(fn
      {:prompt_prefix, text} -> [text]
      _other -> []
    end)
    |> Enum.join("\n\n")
  end

  # Each attachment resolves to exactly one of:
  #   {:inline, block}       — bytes on the wire, no file needed
  #   {:prompt_text, text}   — contents spliced into the prompt
  #   {:file, attachment}    — the staged file itself, by flag or by path
  defp prepare(attachment, mode) do
    cond do
      attachment.kind == :text -> prepare_text(attachment, mode)
      mode == :inline and attachment.kind == :image -> prepare_image(attachment)
      true -> {:file, attachment}
    end
  end

  defp prepare_text(attachment, mode) do
    case read_inlinable(attachment) do
      {:ok, contents} when mode == :inline ->
        {:inline, %{"type" => "text", "text" => wrap_text(attachment, contents)}}

      {:ok, contents} ->
        {:prompt_text, wrap_text(attachment, contents)}

      :error ->
        {:file, attachment}
    end
  end

  # A read failure here is not an error the turn should die on — the file is
  # still staged, so it falls back to the path route that every other kind uses.
  defp prepare_image(attachment) do
    case File.read(attachment.path) do
      {:ok, bytes} -> {:inline, image_block(attachment, Base.encode64(bytes))}
      {:error, _reason} -> {:file, attachment}
    end
  end

  # The Anthropic message format, verified in Phase 0 against claude 2.1.220 on
  # `--input-format stream-json`.
  defp image_block(attachment, data) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => attachment.media_type,
        "data" => data
      }
    }
  end

  defp emit(prepared, backend) do
    files = for {:file, attachment} <- prepared, do: attachment
    {flagged, announced} = Enum.split_with(files, &flag_route?(&1, backend))

    dir_deliveries(backend, announced) ++
      flag_deliveries(backend, flagged) ++
      for({:inline, _block} = delivery <- prepared, do: delivery) ++
      prefix_deliveries(for({:prompt_text, text} <- prepared, do: text), announced)
  end

  # opencode's `-f` takes any file; codex's `-i` takes images only (see the
  # moduledoc). claude has no attachment flag at all, so nothing routes here.
  defp flag_route?(%{kind: :image}, backend), do: backend in [:codex, :opencode]
  defp flag_route?(_attachment, backend), do: backend == :opencode

  # One grant per distinct directory rather than one per attachment: the staging
  # dir is shared, and `--add-dir <same dir>` repeated is noise in every log.
  defp dir_deliveries(backend, announced) do
    for dir <- announced |> Enum.map(&Path.dirname(&1.path)) |> Enum.uniq(),
        args = AgentBackend.dir_grant_args(backend, [dir]),
        args != [],
        do: {:args, args}
  end

  defp flag_deliveries(backend, flagged) do
    case AgentBackend.attachment_args(backend, Enum.map(flagged, & &1.path)) do
      [] -> []
      args -> [{:args, args}]
    end
  end

  defp prefix_deliveries([], []), do: []

  defp prefix_deliveries(texts, announced) do
    [{:prompt_prefix, Enum.join(texts ++ path_section(announced), "\n\n")}]
  end

  defp path_section([]), do: []

  defp path_section(announced) do
    lines =
      Enum.map_join(announced, "\n", fn attachment ->
        "- #{safe_name(attachment.filename)}: #{attachment.path}"
      end)

    ["The user attached these files. Read them from these paths if you need them:\n" <> lines]
  end

  # `bytes` is checked before the read so an oversized file is never loaded into
  # memory just to be rejected; the read is checked again because `bytes` was
  # recorded at staging time and this runs later.
  defp read_inlinable(%{bytes: bytes}) when is_integer(bytes) and bytes > @max_inline_text_bytes,
    do: :error

  defp read_inlinable(attachment) do
    with {:ok, contents} <- File.read(attachment.path),
         true <- byte_size(contents) <= @max_inline_text_bytes,
         true <- String.valid?(contents) do
      {:ok, contents}
    else
      _other -> :error
    end
  end

  defp wrap_text(attachment, contents) do
    name = safe_name(attachment.filename)

    """
    ----- BEGIN ATTACHMENT #{name} -----
    #{contents}
    ----- END ATTACHMENT #{name} -----\
    """
  end

  # The filename is display-only and attacker-influenced (see `Attachment`), and
  # here it lands in a delimiter line. Control characters — a newline above all —
  # would let a name forge its own END marker, so they are flattened.
  defp safe_name(filename) when is_binary(filename) do
    if String.valid?(filename) do
      filename
      |> String.replace(~r/[[:cntrl:]]/u, " ")
      |> String.slice(0, 120)
    else
      "attachment"
    end
  end

  defp safe_name(_filename), do: "attachment"
end
