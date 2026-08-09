defmodule BusterClawWeb.Status.ChatAttachments do
  @moduledoc """
  The visible half of chat attachments: what the composer holds before a send,
  and how a sent attachment is found again afterwards.

  Socket-in / socket-out, like its sibling `BusterClawWeb.Status.Chat`, and its
  own module from the first commit because the roadmap's tail item asked for
  exactly that — `StatusLive` does not need a seventh concern to extract later.

  `BusterClaw.Agent.Attachments` (the store) owns bytes and lifetime. This owns
  the *pending* set, the refusal the user has to see, and the transcript marker.

  ## How a reloaded transcript re-finds its attachments

  This is the one genuinely hard question in Phase 3, and the answer is the same
  one drawings already use: **the transcript is the index, the store is the
  bytes.**

  A drawing survives a reload because its raw ```svg fence is inside the stored
  message and is re-extracted on mount. An attachment's bytes are not in the
  transcript and must not be — a base64 screenshot in an append-only prose log
  would be both enormous and unreadable. So what is stored is the *citation*: a
  ```attachments fence appended to the user message, carrying each attachment's
  id, filename, size and kind. `Chat.emit_message/4` persists user text verbatim,
  so the fence lands in the transcript for free, with no change to the message
  transport.

  On reload `decode/1` strips the fence from the bubble (exactly as
  `SvgViewer.extract/1` strips its own) and `hydrate/2` asks the store for each
  id. The store still has them, because **attachments die with their conversation
  and not with their turn** — the `chat_svgs` rule. So:

  - the store has the file → full chip and thumbnail, as before the reload;
  - the store has lost it → the chip still renders, from the fence alone, marked
    unavailable.

  That second case is why the fence carries filename and size rather than only an
  id. A citation that can only say "attachment 4f2a is gone" is not worth
  storing; one that says "shot.png, 240 KB, no longer available" is.

  ## Why the marker is a fence and not a database column

  Because a column would be a fifth place that has to agree with the other four,
  and because the transcript is *already* the thing that survives a reload. The
  cost is honest and worth naming: **the model sees the fence.** It is a handful
  of tokens on a message that has an attachment anyway, and it is true — files
  were attached.

  ## Previews are capped, and the cap is not cosmetic

  A thumbnail is a `data:` URI built here from the staged bytes. There is no
  image library in this project, so a preview cannot be downscaled — it is the
  whole file, base64'd, in the socket's assigns and in the DOM. A 9 MB photo
  would be 12 MB of markup per render. `@preview_max_bytes` is therefore a real
  memory bound, not a nicety: over it, an image renders as a file chip. It says
  so rather than showing a broken frame.

  ## The zoom modal is reused, not rebuilt

  An image attachment joins the same visual pool as drawings and 3D scenes
  (`chat_svgs`), so `ChatPanel.svg_modal/1` opens it, `zoom_svg` addresses it,
  and ← / → page across every visual in the conversation with no new event and no
  second modal. The pool is a pool of *rendered markup*, which is a slightly
  wider claim than its name makes; an attachment contributes an `<img>`.

  **Pool entries here deliberately skip `SvgViewer.sanitize/1`.** That is not
  laziness: base64 uses `/` and `=`, so a payload can contain the literal
  sequence `/onload=` by chance, and the sanitizer's event-handler regex would
  cut a hole in the middle of a perfectly good image. Nothing in this markup is
  model-authored — the URI is built from bytes the app staged and the only
  attacker-influenced text, the filename, is HTML-escaped on the way into `alt`.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]

  alias BusterClaw.Agent.Attachments

  require Logger

  # The transcript citation. `\\n?` before the close so a fence written by
  # `marker/1` and one hand-edited into a transcript both parse.
  @fence ~r/```attachments\s*\n(.*?)\n?```/s

  # Above this, an image renders as a file chip instead of a preview. See the
  # moduledoc — with no resizer available, a preview is the entire file.
  @preview_max_bytes 1_500_000

  # Types a browser will actually render from a `data:` URI. `image/svg+xml` is
  # deliberately absent: an SVG is a document that can carry script, and the one
  # path that renders model-adjacent SVG live goes through `SvgViewer.sanitize/1`
  # first. An attachment does not, so it does not get to be an SVG preview. This
  # repo already paid for that lesson once (the 07-04 review's SVG XSS finding).
  #
  # Two things make this hold rather than merely intend to. **Whether something
  # is a thumbnail is decided by `media_type`, never by the filename or its
  # extension** — a `.png` suffix on an SVG buys nothing. And the `media_type`
  # consulted is always the *store's*, sniffed from the bytes, never the one in
  # the transcript citation: `hydrate/2` renders a preview only from a record the
  # store returned, so a hand-edited fence claiming `image/png` yields a chip.
  # The client agrees from its end, forcing SVG to `text/plain` before it is
  # ever sent.
  @previewable ~w(image/png image/jpeg image/gif image/webp)

  # Matches `Status.Chat`'s cap on the same pool. Duplicated rather than
  # imported so this module has no dependency on `Status.Chat` — the arrow runs
  # one way, and a cycle between the two would be the seventh thing CI's cycle
  # gate has to argue about.
  @max_pool 200

  # How many files may sit in the composer at once. The store enforces bytes;
  # this enforces patience — five chips is already a wall of thumbnails.
  @max_pending 5

  @doc "Empty composer state. Called by `Status.Chat.init_chats/1` before history loads."
  def init(socket) do
    socket
    |> assign(:chat_attachments, [])
    |> assign(:chat_attach_error, nil)
  end

  @doc "Drop everything the composer is holding — a send, or a conversation switch."
  def clear(socket), do: init(socket)

  @doc "The staged attachments waiting to ride with the next message."
  def pending(socket), do: socket.assigns[:chat_attachments] || []

  # --- staging ---------------------------------------------------------------

  @doc """
  Stage files the Tauri hook dropped on us as absolute paths.

  The path is real and names a file anywhere on the machine (see
  `BusterClaw.Agent.Attachment`'s `t:source/0`), so it is handed to the store
  unread — validation is the store's job and its refusal is surfaced here.
  """
  def stage_paths(socket, paths) when is_list(paths) do
    Enum.reduce(paths, socket, fn
      path, acc when is_binary(path) ->
        stage_one(acc, path, source: :native_path, filename: Path.basename(path))

      _other, acc ->
        acc
    end)
  end

  def stage_paths(socket, _paths), do: socket

  @doc """
  Stage a completed HTML5 upload. `path` is LiveView's temp file, which is why
  the display name has to be passed separately — the temp file's own name is a
  random token.
  """
  def stage_upload(socket, path, filename) do
    stage_one(socket, path, source: :upload, filename: filename)
  end

  defp stage_one(socket, path, opts) do
    filename = Keyword.fetch!(opts, :filename)

    # `media_type` is a *claim* the store checks against the bytes it sniffs, so
    # guessing it from the name is safe and useful — it is the only way a `.md`
    # or a `.csv` becomes `:text` rather than `:binary`, and text is the kind
    # that costs nothing to deliver.
    attrs = %{
      filename: filename,
      media_type: MIME.from_path(filename),
      source: Keyword.fetch!(opts, :source)
    }

    if length(pending(socket)) >= @max_pending do
      refuse(socket, "too_many", filename)
    else
      case normalize_stage(Attachments.stage(conv_id(socket), attrs, {:path, path})) do
        {:ok, attachment} ->
          socket
          |> update(:chat_attachments, &(&1 ++ [render_pending(attachment)]))
          |> assign(:chat_attach_error, nil)

        {:error, reason} ->
          refuse(socket, reason, filename)
      end
    end
  end

  @doc """
  Surface a refusal — the hook's own (`attach_error`), the store's, or ours.

  A refusal is *state*, not a flash: it blocks the next send until it is
  dismissed — see the send gate below.
  """
  def refuse(socket, reason, filename) do
    assign(socket, :chat_attach_error, %{
      reason: to_string(reason),
      filename: to_string(filename || ""),
      message: refusal_message(reason, filename)
    })
  end

  @doc """
  Acknowledge a refusal. One click, and the send gate opens.

  The polite announcement goes with it. A live region that keeps saying "nothing
  was sent" after the thing has been dealt with is a screen reader describing a
  state the screen no longer shows.
  """
  def dismiss_error(socket) do
    socket
    |> assign(:chat_attach_error, nil)
    |> assign(:chat_announcement, nil)
  end

  @doc """
  Take one attachment back out of the composer before it is sent.

  It is removed from the store too. A file the user cancelled has no reason to
  sit in the staging directory until the conversation is deleted.
  """
  def remove(socket, id) do
    case Enum.find(pending(socket), &(&1.id == id)) do
      nil ->
        socket

      _found ->
        Attachments.remove(conv_id(socket), id)
        update(socket, :chat_attachments, fn atts -> Enum.reject(atts, &(&1.id == id)) end)
    end
  end

  @doc "Delete every attachment a conversation staged. Called where a chat is closed."
  def purge(conv_id), do: Attachments.purge(conv_id)

  # --- the send gate ---------------------------------------------------------

  # Why this message must not be sent yet, or `nil`.
  #
  # Silently sending a message whose image did not make it is the failure users
  # hate most, so the two ways that can happen both stop the send:
  #
  # 1. an attachment was refused and the user has not acknowledged it — they may
  #    well want to retry rather than send without it;
  # 2. something staged has vanished from disk between the drop and the send.
  #
  # Both are recoverable in one click, which is the only reason blocking (rather
  # than warning) is defensible.
  defp send_block(socket) do
    gone = Enum.reject(pending(socket), &staged?(socket, &1))

    cond do
      socket.assigns[:chat_attach_error] ->
        "Nothing was sent. An attachment was refused — remove it or dismiss the warning, then send again."

      gone != [] ->
        "Nothing was sent. #{Enum.map_join(gone, ", ", & &1.filename)} is no longer staged — drop it again."

      true ->
        nil
    end
  end

  @doc """
  The send gate itself: `{:ok, socket}` or `{:blocked, socket}` with the refusal
  made visible.

  A blocked send must *say so on screen*. When the banner is already up (the
  common case) the specific reason is kept and a "nothing was sent" line is added
  to it — replacing it with a generic message would throw away the only sentence
  that tells the user which file and why.
  """
  def gate(socket) do
    case send_block(socket) do
      nil ->
        {:ok, socket}

      message ->
        existing =
          socket.assigns[:chat_attach_error] ||
            %{reason: "unstaged", filename: "", message: message}

        {:blocked,
         socket
         |> assign(:chat_attach_error, Map.put(existing, :blocked, message))
         |> assign(:chat_announcement, message)}
    end
  end

  defp staged?(socket, attachment) do
    case normalize_get(Attachments.get(conv_id(socket), attachment.id)) do
      nil -> false
      staged -> File.exists?(staged.path)
    end
  end

  # --- the transcript marker -------------------------------------------------

  @doc """
  Append the citation fence to the text that will be persisted.

  Returns the text unchanged when there is nothing to cite, so an ordinary
  message is byte-identical to what it was before attachments existed.
  """
  def marker(text, []), do: text

  def marker(text, attachments) do
    json =
      attachments
      |> Enum.map(fn a ->
        %{
          "id" => a.id,
          "filename" => a.filename,
          "bytes" => a.bytes,
          "kind" => to_string(a.kind),
          "media_type" => a.media_type
        }
      end)
      |> Jason.encode!()

    String.trim("#{text}\n\n```attachments\n#{json}\n```")
  end

  @doc """
  Split a stored message into what the bubble shows and what it cited.

  The mirror of `SvgViewer.extract/1`, and for the same reason: the raw marker
  must never reach the reader.
  """
  def decode(text) when is_binary(text) do
    metas =
      @fence
      |> Regex.scan(text)
      |> Enum.flat_map(fn [_full, body] -> parse_metas(body) end)

    {@fence |> Regex.replace(text, "") |> String.trim(), metas}
  end

  def decode(other), do: {other, []}

  defp parse_metas(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> Enum.flat_map(list, &parse_meta/1)
      _ -> []
    end
  end

  defp parse_meta(%{"id" => id, "filename" => name} = m) when is_binary(id) and is_binary(name) do
    [
      %{
        id: id,
        filename: name,
        bytes: meta_int(m["bytes"]),
        kind: meta_kind(m["kind"]),
        media_type: if(is_binary(m["media_type"]), do: m["media_type"], else: "")
      }
    ]
  end

  defp parse_meta(_other), do: []

  defp meta_int(n) when is_integer(n) and n >= 0, do: n
  defp meta_int(_other), do: 0

  defp meta_kind(k) when k in ["image", "text", "binary"], do: String.to_existing_atom(k)
  defp meta_kind(_other), do: :binary

  # --- rendering -------------------------------------------------------------

  @doc """
  Turn cited metadata back into something the transcript can draw.

  The store supplies the bytes; the citation supplies everything else, so a
  message whose file the store has lost still renders a named, sized chip
  instead of disappearing.
  """
  def hydrate(_conv_id, []), do: []

  def hydrate(conv_id, metas) do
    Enum.map(metas, fn meta ->
      case normalize_get(Attachments.get(conv_id, meta.id)) do
        nil -> Map.merge(meta, %{preview: nil, available?: false, size_label: label(meta.bytes)})
        staged -> render_pending(staged)
      end
    end)
  end

  @doc """
  Rebuild the *composer's* pending set after a reload.

  A file dropped and never sent is still staged — the store keys by conversation,
  not by turn — so the chips can come back rather than leaving an orphan on disk
  that nothing on screen admits to. `sent_ids` are the ids already cited by the
  transcript; everything else the store is holding for this conversation is, by
  definition, still waiting in the composer.
  """
  def recover_pending(socket, conv_id, sent_ids) do
    pending =
      conv_id
      |> Attachments.list()
      |> normalize_list()
      |> Enum.reject(&(&1.id in sent_ids))
      |> Enum.map(&render_pending/1)

    socket
    |> assign(:chat_attachments, pending)
    |> assign(:chat_attach_error, nil)
  end

  # Everything the chip and the bubble need, computed once at staging time so a
  # re-render never re-reads the file.
  defp render_pending(attachment) do
    %{
      id: attachment.id,
      filename: attachment.filename,
      bytes: attachment.bytes,
      kind: attachment.kind,
      media_type: attachment.media_type,
      size_label: label(attachment.bytes),
      preview: preview_uri(attachment),
      available?: true
    }
  end

  defp preview_uri(%{media_type: type, bytes: bytes, path: path})
       when is_binary(path) do
    with true <- type in @previewable,
         true <- bytes <= @preview_max_bytes,
         {:ok, binary} <- File.read(path) do
      "data:" <> type <> ";base64," <> Base.encode64(binary)
    else
      _ -> nil
    end
  end

  defp preview_uri(_attachment), do: nil

  @doc """
  Give each previewable attachment a slot in the conversation's visual pool,
  starting at `next`.

  Returns `{attachments, pool_entries, next_id}` so both the live path and
  history replay number visuals from the same counter — a bubble's `zoom_svg`
  id and the modal's paging order cannot drift apart.
  """
  def number(attachments, next) do
    {rev, pool, next} =
      Enum.reduce(attachments, {[], [], next}, fn att, {acc, pool, id} ->
        if att.preview do
          {[Map.put(att, :pool_id, id) | acc], [%{id: id, svg: img_markup(att)} | pool], id + 1}
        else
          {[Map.put(att, :pool_id, nil) | acc], pool, id}
        end
      end)

    {Enum.reverse(rev), Enum.reverse(pool), next}
  end

  @doc """
  Number this batch against the socket's live counter and fold it into the pool.

  The live counterpart of `number/2`, matching `Status.Chat.collect_svgs/2`'s
  contract (it numbers a batch `svg_seq+1 .. svg_seq+n`).
  """
  def place_in_pool(socket, attachments) do
    {attachments, pool, next} = number(attachments, socket.assigns.svg_seq + 1)

    socket =
      socket
      |> assign(:svg_seq, next - 1)
      |> update(:chat_svgs, fn svgs -> cap(svgs ++ pool, @max_pool) end)

    {socket, attachments}
  end

  defp cap(list, max) do
    over = length(list) - max
    if over > 0, do: Enum.drop(list, over), else: list
  end

  # The pool entry. NOT run through `SvgViewer.sanitize/1` — see the moduledoc.
  defp img_markup(att) do
    ~s(<img src="#{att.preview}" alt="#{escape(att.filename)}" ) <>
      ~s(class="block h-auto max-h-[80vh] w-auto max-w-[86vw]" />)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  @doc "Human file size for a chip. Rounded, because a chip is not a ledger."
  def label(bytes) when is_integer(bytes) and bytes < 1_024, do: "#{bytes} B"

  def label(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  def label(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  def label(_bytes), do: ""

  # --- refusal copy ----------------------------------------------------------

  # The hook, the store and this module all refuse in the same vocabulary, so
  # the user reads one sentence rather than an atom. The client's own set is
  # `unsupported_type` / `too_large` / `too_many` / `empty` / `bad_filename` /
  # `unavailable`; the store's is `t:BusterClaw.Agent.Attachments.error/0`. An
  # unknown reason still gets a sentence — falling through to a bare atom is how
  # a user ends up reading `:enoent`.
  defp refusal_message(reason, filename) do
    name = if filename in [nil, ""], do: "That file", else: filename

    case to_string(reason) do
      "too_large" -> "#{name} is too large to attach."
      "empty" -> "#{name} is empty, so there is nothing to attach."
      "too_many" -> "#{name} was not attached — only #{@max_pending} files at a time."
      "conversation_full" -> "#{name} does not fit — this chat is already holding its limit."
      "unsupported_type" -> "#{name} is not a kind of file that can be attached."
      "bad_filename" -> "That file's name could not be used, so it was not attached."
      "unavailable" -> "#{name} could not be attached — this chat cannot take files right now."
      "not_regular" -> "#{name} is not a file — folders and links cannot be attached."
      "unreadable" -> "#{name} could not be read."
      "not_found" -> "#{name} could not be found."
      "enoent" -> "#{name} could not be found."
      "invalid_path" -> "#{name} is not a path that can be attached."
      other -> "#{name} could not be attached (#{other})."
    end
  end

  # --- store shapes ----------------------------------------------------------
  #
  # The store's return shapes were not pinned by `Agent.Attachment` (it is types
  # only), so both the bare-value and tagged-tuple conventions are accepted here
  # rather than guessed at. This is the seam to tighten once the store lands —
  # it costs two functions and it means a reasonable store cannot break this UI.

  defp normalize_stage({:ok, attachment}) when is_map(attachment), do: {:ok, attachment}
  defp normalize_stage({:error, reason}), do: {:error, reason}
  defp normalize_stage(attachment) when is_map(attachment), do: {:ok, attachment}
  defp normalize_stage(other), do: {:error, inspect(other)}

  defp normalize_get({:ok, attachment}) when is_map(attachment), do: attachment
  defp normalize_get(attachment) when is_map(attachment), do: attachment
  defp normalize_get(_other), do: nil

  defp normalize_list({:ok, list}) when is_list(list), do: list
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_other), do: []

  defp conv_id(socket), do: socket.assigns.active_chat
end
