defmodule BusterClaw.Agent.Attachments do
  @moduledoc """
  The staging store for chat attachments — the one place a file dropped or pasted
  into the homepage chat is written, listed, and thrown away.

  `BusterClaw.Agent.Attachment` defines the shape and the reasoning; this module
  is the only thing that puts one on disk. It speaks to no backend and renders
  nothing: everything above it (the dropzone hook, the delivery layer, the
  transcript) reads a `t:BusterClaw.Agent.Attachment.t/0` and never a raw upload.

  **Why a file exists at all** is measured, not assumed (roadmap Phase 0): Codex
  takes `-i/--image <FILE>` and OpenCode takes `-f/--file`, and **neither accepts
  bytes**. A staged file is therefore the substrate all three backends share.
  Claude's inline base64 block is an optimisation on one path of one backend, not
  an alternative to this store.

  ## Where staging lives, and why it is not the workspace

      ~/Library/Caches/buster-claw/attachments/<conversation-id>/<id><ext>
      (`:filename.basedir(:user_cache, "buster-claw")`, so Linux gets
       `~/.cache/buster-claw/attachments/…`)

  Overridable with `config :buster_claw, :attachments_root` — which is how the
  test suite points it at a tmp dir, and the only supported way to move it.

  **It is deliberately outside the workspace tree the agent browses.** The
  operator's constraint (08-08) was that the model must not be saving images into
  the user's own filesystem without being asked, so a dropped screenshot must not
  become a permanent artifact in `~/Desktop/BusterClawCLI` or turn up in a `ls` of
  the workspace three weeks later. The agent reaches a staged file only because a
  backend was handed **that specific path** (Claude's `--add-dir`, Codex's `-i`,
  OpenCode's `-f`) for one turn. It is never discovered by browsing.

  The OS cache directory rather than `System.tmp_dir!/0` for two reasons: the app
  is the only writer under an app-named directory (a shared `/tmp` is a namespace
  anyone can collide with or pre-create a symlink in), and a staged file has to
  survive an app restart, because Phase 3 requires an attachment still rendering
  in its transcript after a reload. "Cache" is the honest label — the contents are
  reconstructible from nothing and losing them costs one re-drop.

  ## Layout, and what a sidecar is for

  One directory per conversation, and inside it, per attachment:

      <id><ext>          the bytes
      <id>.meta.json     filename, media type, kind, size, source, staged_at

  The metadata is a sidecar rather than one index per conversation because two
  drops land from the same LiveView within milliseconds of each other, and a
  read-modify-write of a shared index is a lost-update bug waiting for a fast
  user. A sidecar has one writer, ever. The payload is written first and the
  sidecar second, so a crash between them leaves a file `list/1` does not report
  and `sweep/1` later collects — an orphan, never a half-visible attachment.

  ## `filename` is attacker-influenced and NEVER becomes a path

  The name comes from the DOM or from a `Content-Disposition`-shaped string, and
  is display-only in the contract. This module honours that literally: **the
  on-disk name is generated here** — 96 random bits, url-safe base64 — and the
  extension is looked up from the *classified* media type in a fixed table. No
  byte of the user's filename reaches `Path.join/2`. `../../etc/passwd`, a name
  with a NUL, a 3000-character name and a name that is `.` are all staged
  successfully, all inside the conversation's directory, because the name was
  never consulted.

  The name is still cleaned before it is *stored*, for display hygiene only:
  invalid UTF-8, control characters, and everything before the last separator go,
  and it is truncated. That is a chip-rendering concern, not the containment.

  ## A `:native_path` names any file on the machine

  Tauri's drag-drop hands over a real absolute path, which is read on the user's
  behalf. Before anything is read: no NUL, absolute, sane length, and
  `File.lstat/1` must report a **regular file** — which rejects directories,
  fifos, `/dev/zero`, and symlinks outright.

  Symlinks are refused rather than resolved-and-checked. A Finder drag delivers
  the resolved path already, so nothing legitimate is lost, and "resolve then
  decide whether the target is sane" is a rule with no non-arbitrary answer.

  **The size is taken from `File.stat/1` before a single byte is read**, and the
  copy itself is bounded (`File.copy/3` with a byte count), so a file swapped for
  a 10 GB one between the stat and the copy still cannot run away. Reading first
  and checking after is how a large drop takes the app down.

  ## The type is sniffed, not believed

  The browser's media type and the file's extension are both attacker-supplied
  and both are ignored for classification. The first 4 KB are matched
  against magic numbers — PNG, JPEG, GIF, WEBP, PDF — and what the file *is*
  decides `kind`. This matters because `kind` is what the delivery layer switches
  on to pick a backend flag: a file claiming `image/png` that is not a PNG must
  not be handed to `--image`, and a real PNG claiming `text/plain` must not be
  pasted into the prompt as text.

  Anything with no known magic is text or binary by inspection of that same head:
  valid UTF-8 with no NUL and no stray control bytes is `:text`, otherwise
  `:binary`. Honest limits: this is a **head** heuristic, so a text file with a
  binary blob past the first 4 KB still classifies as text, and UTF-16 (NUL-rich)
  classifies as binary. A returned `media_type` is always one this module chose —
  a sniffed type, a declared *text* type from a small allowlist, or
  `application/octet-stream`.

  `:text` attachments are staged too, even though the consumer inlines them and
  needs no file. One pipeline with a uniform shape beats a special case that only
  the text path exercises.

  ## Caps, enforced at the drop

  Per-file, per-conversation total, and per-conversation count — see the module
  attributes for the numbers and the reasoning behind each. All three are checked
  **before** the bytes are written, because the roadmap's requirement is that an
  over-size drop is refused where the refusal is still cheap and visible, not
  after an upload that appeared to succeed.

  ## Lifetime

  `purge/1` on conversation deletion: attachments die with their conversation,
  which is the `chat_svgs` rule applied unchanged. `sweep/1` is the backstop for
  everything else — a crash mid-turn, a tab closed without sending, a conversation
  row deleted by a migration that never called us. Without it a staged file leaks
  disk forever.

  ## Totality

  Nothing here raises. A missing directory, a hand-edited sidecar, a path that
  vanished between the stat and the copy, a filename that is not valid UTF-8: each
  has a named result. `list/1` returns `[]` rather than an error, since a
  conversation with no directory and a conversation with no attachments are the
  same answer.
  """

  alias BusterClaw.Agent.Attachment

  @app "buster-claw"
  @subdir "attachments"
  @meta_ext ".meta.json"
  @meta_version 1

  # 10 MB. A 4K screenshot lands at 5-8 MB and a phone photo at 3-5 MB, so this
  # clears the drops people actually make with room to spare while still bounding
  # the worst case. It is also the number that keeps Claude's inline path sane:
  # base64 inflates by ~4/3, so a 10 MB image is a ~13.4 MB single JSON line on a
  # subprocess's stdin. Raising this without measuring that line is how the
  # streaming path starts truncating.
  @max_file_bytes 10 * 1024 * 1024

  # 50 MB — five max-size files. This is the cap on how much disk one
  # conversation can hold hostage between a drop and a purge, and it is deliberate
  # that it is not `count * file_cap`: twenty 10 MB images is not a chat message,
  # it is a backup.
  @max_conversation_bytes 50 * 1024 * 1024

  # 20 attachments. Above this the composer's chip row stops being readable, and
  # the delivery layer would be appending 20 `-i` flags to an argv. Every real
  # attachment message is one to five files.
  @max_conversation_count 20

  # 24 hours. Long enough that a staged file outlives any turn, a crash, and a
  # user who walks away mid-compose; short enough that a leak is a day of disk,
  # not a year of it. Only reached by files `purge/1` never got to.
  @ttl_seconds 24 * 60 * 60

  # Enough head to hold every magic number with room over, and to make the
  # text/binary call on something more representative than a first line.
  @sniff_bytes 4096

  # Display only. Long enough to keep a real name recognisable in a chip.
  @max_filename_length 120
  @fallback_filename "attachment"

  # A path longer than this is not a file a human dragged.
  @max_path_length 4096

  # url-safe base64 and nothing else: this is the charset `new_id/0` emits and
  # the charset `Agent.Conversations` emits for a conversation id. Anything that
  # could traverse, hide, or name a device is outside it by construction.
  @token ~r/\A[A-Za-z0-9_-]{1,64}\z/

  # A media type token, syntax only. Validated before it is looked up, never
  # trusted for what it claims the bytes are.
  @media_type ~r/\A[a-z0-9][a-z0-9!$&^_.+-]{0,62}\/[a-z0-9][a-z0-9!$&^_.+-]{0,62}\z/

  # The declared media type is honoured ONLY for text, ONLY from this list, and
  # ONLY after the bytes have already been shown to be text. It buys a useful
  # extension for the model to read and nothing else.
  @text_types %{
    "text/plain" => ".txt",
    "text/markdown" => ".md",
    "text/x-markdown" => ".md",
    "text/csv" => ".csv",
    "text/html" => ".html",
    "text/xml" => ".xml",
    "text/yaml" => ".yaml",
    "text/javascript" => ".js",
    "text/x-python" => ".py",
    "application/json" => ".json",
    "application/xml" => ".xml",
    "application/x-yaml" => ".yaml",
    "application/javascript" => ".js"
  }

  # Every extension this module can ever put on disk. Derived from the type we
  # classified, never from the name we were given.
  @extensions %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "application/pdf" => ".pdf",
    "application/octet-stream" => ".bin"
  }

  @typedoc "A conversation id, as minted by `BusterClaw.Agent.Conversations`."
  @type conversation_id :: String.t()

  @typedoc "An attachment id, stable within its conversation."
  @type id :: String.t()

  @typedoc """
  What to stage. A bare binary is **always** read as bytes and never as a path:
  misreading bytes as a path fails closed, while the reverse would open an
  arbitrary file because a caller passed the wrong thing.
  """
  @type payload :: binary() | {:bytes, binary()} | {:path, String.t()}

  @typedoc """
  Why a call was refused. Every one of these is returned, never raised.

  - `:invalid_conversation` — the id is not a conversation id shape.
  - `:invalid_attrs` / `:invalid_source` / `:invalid_payload` — malformed call.
  - `:invalid_path` — not absolute, too long, or contains a NUL.
  - `:not_regular` — a directory, device, fifo, or symlink was named.
  - `:too_large` — over the per-file cap. Raised by the stat, before any read.
  - `:empty` — a zero-byte file. Refused rather than staged as a chip that
    carries nothing.
  - `:too_many` / `:conversation_full` — the per-conversation count and byte caps.
  - `:unreadable` — the path exists and could not be opened.
  - `:not_found` — no such attachment in that conversation.
  """
  @type error ::
          :invalid_conversation
          | :invalid_attrs
          | :invalid_source
          | :invalid_payload
          | :invalid_path
          | :not_regular
          | :too_large
          | :empty
          | :too_many
          | :conversation_full
          | :unreadable
          | :not_found
          | :file.posix()

  # ---------------------------------------------------------------------------
  # Location
  # ---------------------------------------------------------------------------

  @doc """
  The staging root — an app-managed directory **outside the workspace**.

  See the moduledoc for why it is the OS cache directory and not the workspace or
  `/tmp`. `config :buster_claw, :attachments_root` overrides it.
  """
  @spec root() :: String.t()
  def root do
    case Application.get_env(:buster_claw, :attachments_root) do
      nil -> Path.join(:filename.basedir(:user_cache, @app), @subdir)
      value when is_binary(value) -> Path.expand(value)
      value when is_list(value) -> Path.expand(List.to_string(value))
      _other -> Path.join(:filename.basedir(:user_cache, @app), @subdir)
    end
  end

  @doc """
  Absolute path of one conversation's staging directory.

  This is the directory a backend is granted for a turn (`--add-dir`), which is
  why it is public: the delivery layer needs it without reconstructing the layout.
  """
  @spec dir(term()) :: {:ok, String.t()} | {:error, error()}
  def dir(conversation_id) do
    case conversation(conversation_id) do
      {:ok, conv} -> {:ok, Path.join(root(), conv)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The enforced limits, so the composer can say them before a drop rather than
  after one.
  """
  @spec limits() :: %{
          max_file_bytes: pos_integer(),
          max_conversation_bytes: pos_integer(),
          max_conversation_count: pos_integer(),
          ttl_seconds: pos_integer()
        }
  def limits do
    %{
      max_file_bytes: @max_file_bytes,
      max_conversation_bytes: @max_conversation_bytes,
      max_conversation_count: @max_conversation_count,
      ttl_seconds: @ttl_seconds
    }
  end

  # ---------------------------------------------------------------------------
  # Staging
  # ---------------------------------------------------------------------------

  @doc """
  Stage one attachment against a conversation and return it.

  `attrs` carries `:filename` (display only), `:media_type` (a claim, checked
  against the bytes) and `:source` (`:upload` or `:native_path`). String keys work
  too, so a decoded client payload and a hand-built map take the same path.

  The payload is bytes (`{:bytes, data}`, or a bare binary) or a path to copy
  (`{:path, "/abs/path"}`). `:source` records provenance for the transcript; the
  *payload tag* decides what is read, and a path is validated identically no
  matter which source claimed it.

  Order of operations is the security story: validate the conversation, gate the
  path, take the size **before reading**, sniff the head, check all three caps,
  and only then write. Failure at any step leaves nothing on disk.
  """
  @spec stage(term(), map(), payload()) :: {:ok, Attachment.t()} | {:error, error()}
  def stage(conversation_id, attrs, payload) when is_map(attrs) do
    with {:ok, conv} <- conversation(conversation_id),
         {:ok, source} <- source(attrs),
         {:ok, plan} <- inspect_payload(payload),
         :ok <- room_for(conv, plan.size) do
      write(conv, plan, attrs, source)
    end
  end

  def stage(_conversation_id, _attrs, _payload), do: {:error, :invalid_attrs}

  # ---------------------------------------------------------------------------
  # Reading back
  # ---------------------------------------------------------------------------

  @doc """
  Everything staged against a conversation, oldest first.

  Never errors: an unknown or malformed conversation id, a missing directory, and
  an empty one all answer `[]`. Orphans — a payload whose sidecar never landed, or
  a sidecar whose payload is gone — are not reported; `sweep/1` collects them.
  """
  @spec list(term()) :: [Attachment.t()]
  def list(conversation_id) do
    case dir(conversation_id) do
      {:ok, path} -> entries(path)
      {:error, _reason} -> []
    end
  end

  @doc """
  One attachment by id, scoped to its conversation.

  **The scope is the containment**: an id belonging to another conversation is
  `:not_found` here, because ids are resolved inside one directory and never
  searched for globally. A malformed id is `:not_found` for the same reason it is
  not `:invalid` — there is no id it could have been.
  """
  @spec get(term(), term()) :: {:ok, Attachment.t()} | {:error, :not_found}
  def get(conversation_id, id) do
    with {:ok, wanted} <- token(id),
         %{} = found <- Enum.find(list(conversation_id), &(&1.id == wanted)) do
      {:ok, found}
    else
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Drop one staged attachment — what the composer's chip "x" calls before sending.

  Removes the bytes and the sidecar. `:not_found` if it was already gone.
  """
  @spec remove(term(), term()) :: :ok | {:error, error()}
  def remove(conversation_id, id) do
    case get(conversation_id, id) do
      {:ok, found} -> delete_files(found.path)
      {:error, _reason} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Lifetime
  # ---------------------------------------------------------------------------

  @doc """
  Delete everything staged for a conversation. **Call this when a conversation is
  deleted** — attachments die with their conversation, the `chat_svgs` rule.

  Always `:ok`, including for a conversation that never staged anything and for an
  id that is not a conversation id at all. Deleting a conversation must never be
  blocked by its attachments, and "there is nothing of yours on disk" is a true
  answer to both. Nothing is touched in the malformed case, since the directory is
  only ever built from a validated id.
  """
  @spec purge(term()) :: :ok
  def purge(conversation_id) do
    case dir(conversation_id) do
      {:ok, path} -> discard_dir(path)
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Remove staged files older than the TTL, across every conversation, and report
  how many attachments went.

  The backstop for everything `purge/1` never hears about: a crash mid-turn, a
  composer abandoned with chips in it, a conversation row deleted by something
  that did not call us. Without it a staged file leaks disk forever.

  Age is the payload file's mtime, which this module set when it wrote it — a
  copy writes a fresh file, so a source file's old mtime is not inherited.
  Options: `:ttl_seconds` and `:now` (unix seconds), both for tests.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()}
  def sweep(opts \\ []) when is_list(opts) do
    ttl = Keyword.get(opts, :ttl_seconds, @ttl_seconds)
    now = Keyword.get(opts, :now, System.os_time(:second))
    cutoff = now - ttl

    removed =
      root()
      |> conversation_dirs()
      |> Enum.map(&sweep_dir(&1, cutoff))
      |> Enum.sum()

    {:ok, removed}
  end

  # ---------------------------------------------------------------------------
  # The conversation and id gates. Every entry point goes through these.
  # ---------------------------------------------------------------------------

  defp conversation(id) when is_binary(id) do
    if Regex.match?(@token, id), do: {:ok, id}, else: {:error, :invalid_conversation}
  end

  defp conversation(_id), do: {:error, :invalid_conversation}

  defp token(id) when is_binary(id) do
    if Regex.match?(@token, id), do: {:ok, id}, else: :error
  end

  defp token(_id), do: :error

  # ---------------------------------------------------------------------------
  # Looking at the payload without committing to it
  # ---------------------------------------------------------------------------

  defp inspect_payload({:bytes, data}) when is_binary(data), do: from_bytes(data)
  defp inspect_payload({:path, path}), do: from_path(path)
  defp inspect_payload(data) when is_binary(data), do: from_bytes(data)
  defp inspect_payload(_other), do: {:error, :invalid_payload}

  defp from_bytes(data) do
    size = byte_size(data)

    cond do
      size == 0 ->
        {:error, :empty}

      size > @max_file_bytes ->
        {:error, :too_large}

      true ->
        {:ok,
         %{size: size, head: binary_part(data, 0, min(size, @sniff_bytes)), put: {:bytes, data}}}
    end
  end

  defp from_path(path) when is_binary(path) do
    with :ok <- safe_path(path),
         {:ok, size} <- regular_size(path),
         {:ok, head} <- read_head(path) do
      {:ok, %{size: size, head: head, put: {:copy, path}}}
    end
  end

  defp from_path(_path), do: {:error, :invalid_path}

  # A NUL in a path makes `File.stat/1` raise, so it is checked before anything
  # is handed to the filesystem rather than as part of the stat.
  defp safe_path(path) do
    cond do
      String.contains?(path, <<0>>) -> {:error, :invalid_path}
      byte_size(path) > @max_path_length -> {:error, :invalid_path}
      Path.type(path) != :absolute -> {:error, :invalid_path}
      true -> :ok
    end
  end

  # `lstat`, not `stat`: a symlink must be seen as a symlink and refused, rather
  # than silently resolved to whatever it points at. The size is taken here,
  # before a byte is read, which is the whole point of this function.
  defp regular_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> sized(size)
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp sized(0), do: {:error, :empty}
  defp sized(size) when size > @max_file_bytes, do: {:error, :too_large}
  defp sized(size), do: {:ok, size}

  defp read_head(path) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} -> close_after(fd, :file.read(fd, @sniff_bytes))
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp close_after(fd, result) do
    :file.close(fd)

    case result do
      {:ok, head} -> {:ok, head}
      :eof -> {:error, :empty}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  # ---------------------------------------------------------------------------
  # Caps
  # ---------------------------------------------------------------------------

  defp room_for(conv, size) do
    staged = entries(Path.join(root(), conv))
    total = staged |> Enum.map(& &1.bytes) |> Enum.sum()

    cond do
      length(staged) >= @max_conversation_count -> {:error, :too_many}
      total + size > @max_conversation_bytes -> {:error, :conversation_full}
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write(conv, plan, attrs, source) do
    {media_type, kind} = classify(plan.head, pick(attrs, :media_type))
    id = new_id()
    dir = Path.join(root(), conv)
    path = Path.join(dir, id <> extension(media_type))

    with :ok <- File.mkdir_p(dir),
         {:ok, bytes} <- put(plan.put, path) do
      record(dir, id, %{
        id: id,
        conversation_id: conv,
        filename: display_name(pick(attrs, :filename)),
        media_type: media_type,
        kind: kind,
        bytes: bytes,
        path: path,
        source: source
      })
    end
  end

  defp put({:bytes, data}, path) do
    case File.write(path, data) do
      :ok -> {:ok, byte_size(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Bounded copy. The stat above already refused anything over the cap, but the
  # file can be replaced between the two calls, so the copy itself is given a
  # ceiling: at most one byte more than the cap is ever read, and a file that grew
  # past it is deleted rather than staged.
  defp put({:copy, source}, path) do
    case File.copy(source, path, @max_file_bytes + 1) do
      {:ok, copied} when copied > 0 and copied <= @max_file_bytes -> {:ok, copied}
      {:ok, _copied} -> discard(path, :too_large)
      {:error, reason} -> discard(path, reason)
    end
  end

  defp discard(path, reason) do
    File.rm(path)
    {:error, reason}
  end

  # The sidecar lands last, so a crash leaves an orphan `sweep/1` collects rather
  # than an attachment `list/1` reports without knowing what it is.
  defp record(dir, id, entry) do
    meta = %{
      "version" => @meta_version,
      "id" => id,
      "file" => Path.basename(entry.path),
      "filename" => entry.filename,
      "media_type" => entry.media_type,
      "kind" => Atom.to_string(entry.kind),
      "bytes" => entry.bytes,
      "source" => Atom.to_string(entry.source),
      "staged_at" => System.os_time(:second)
    }

    with {:ok, json} <- encode(meta),
         :ok <- File.write(Path.join(dir, id <> @meta_ext), json) do
      {:ok, entry}
    else
      {:error, reason} -> discard(entry.path, reason)
    end
  end

  defp encode(meta) do
    case Jason.encode(meta) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :invalid_attrs}
    end
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  # ---------------------------------------------------------------------------
  # Classification — magic bytes first, claims never
  # ---------------------------------------------------------------------------

  defp classify(head, declared) do
    case sniff(head) do
      {media_type, kind} -> {media_type, kind}
      :unknown -> unsniffable(head, declared)
    end
  end

  defp sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: {"image/png", :image}
  defp sniff(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {"image/jpeg", :image}
  defp sniff(<<"GIF8", _rest::binary>>), do: {"image/gif", :image}
  defp sniff(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: {"image/webp", :image}
  defp sniff(<<"%PDF-", _rest::binary>>), do: {"application/pdf", :binary}
  defp sniff(_head), do: :unknown

  defp unsniffable(head, declared) do
    if text?(head) do
      {declared_text_type(declared), :text}
    else
      {"application/octet-stream", :binary}
    end
  end

  # Valid UTF-8, no NUL, no control bytes outside the ones text actually uses.
  # A head, not the whole file — see the moduledoc on what that misses.
  defp text?(head) do
    trimmed = trim_partial(head)

    trimmed != "" and String.valid?(trimmed) and not String.contains?(trimmed, <<0>>) and
      not Regex.match?(~r/[\x01-\x08\x0e-\x1f]/, trimmed)
  end

  # The head can cut a multi-byte character in half, which would fail
  # `String.valid?/1` for a reason that says nothing about the file.
  defp trim_partial(head) do
    Enum.find_value(0..3, "", fn drop ->
      size = byte_size(head) - drop
      candidate = if size > 0, do: binary_part(head, 0, size), else: ""
      if String.valid?(candidate), do: candidate
    end)
  end

  defp declared_text_type(declared) do
    normalized = normalize_media_type(declared)
    if Map.has_key?(@text_types, normalized), do: normalized, else: "text/plain"
  end

  defp normalize_media_type(declared) when is_binary(declared) do
    token =
      declared
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()

    if Regex.match?(@media_type, token), do: token, else: ""
  end

  defp normalize_media_type(_declared), do: ""

  # Never from the filename, never from the claim: from the type we classified.
  defp extension(media_type) do
    Map.get(@extensions, media_type) || Map.get(@text_types, media_type) || ".bin"
  end

  # ---------------------------------------------------------------------------
  # The display name — hygiene, not containment
  # ---------------------------------------------------------------------------

  defp display_name(name) when is_binary(name) do
    if String.valid?(name), do: clean_name(name), else: @fallback_filename
  end

  defp display_name(_name), do: @fallback_filename

  defp clean_name(name) do
    cleaned =
      name
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.split(["/", "\\"])
      |> Enum.reject(&(&1 == ""))
      |> List.last()
      |> to_string()
      |> String.trim()

    if cleaned in ["", ".", ".."] do
      @fallback_filename
    else
      String.slice(cleaned, 0, @max_filename_length)
    end
  end

  # ---------------------------------------------------------------------------
  # Reading the store back
  # ---------------------------------------------------------------------------

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&meta?/1) |> Enum.flat_map(&entry(dir, &1))
      {:error, _reason} -> []
    end
  end

  defp meta?(name), do: String.ends_with?(name, @meta_ext)

  defp entry(dir, name) do
    with {:ok, body} <- File.read(Path.join(dir, name)),
         {:ok, meta} <- Jason.decode(body),
         {:ok, staged} <- from_meta(dir, meta) do
      [staged]
    else
      _other -> []
    end
  end

  # The sidecar is ours, but it is a file on a disk the user can edit, so its
  # `file` is re-validated as a bare basename in our own charset before it is
  # joined to anything.
  defp from_meta(dir, %{"id" => id, "file" => file} = meta) when is_binary(file) do
    path = Path.join(dir, file)

    with {:ok, checked} <- token(id),
         true <- Path.basename(file) == file and String.starts_with?(file, checked),
         true <- File.regular?(path) do
      {:ok, built(dir, checked, path, meta)}
    else
      _other -> :error
    end
  end

  defp from_meta(_dir, _meta), do: :error

  defp built(dir, id, path, meta) do
    %{
      id: id,
      conversation_id: Path.basename(dir),
      filename: display_name(Map.get(meta, "filename")),
      media_type: media_type_of(meta),
      kind: kind_of(Map.get(meta, "kind")),
      bytes: bytes_of(Map.get(meta, "bytes")),
      path: path,
      source: source_of(Map.get(meta, "source"))
    }
  end

  defp media_type_of(meta) do
    normalized = normalize_media_type(Map.get(meta, "media_type"))

    if Map.has_key?(@extensions, normalized) or Map.has_key?(@text_types, normalized) do
      normalized
    else
      "application/octet-stream"
    end
  end

  defp kind_of("image"), do: :image
  defp kind_of("text"), do: :text
  defp kind_of(_other), do: :binary

  defp source_of("native_path"), do: :native_path
  defp source_of(_other), do: :upload

  defp bytes_of(value) when is_integer(value) and value >= 0, do: value
  defp bytes_of(_value), do: 0

  # ---------------------------------------------------------------------------
  # Deleting
  # ---------------------------------------------------------------------------

  defp delete_files(path) do
    File.rm(meta_path(path))

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp meta_path(path) do
    Path.join(Path.dirname(path), Path.rootname(Path.basename(path)) <> @meta_ext)
  end

  defp discard_dir(path) do
    File.rm_rf(path)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Sweeping
  # ---------------------------------------------------------------------------

  defp conversation_dirs(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@token, &1))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _reason} ->
        []
    end
  end

  defp sweep_dir(dir, cutoff) do
    removed =
      case File.ls(dir) do
        {:ok, names} -> names |> Enum.map(&sweep_file(dir, &1, cutoff)) |> Enum.sum()
        {:error, _reason} -> 0
      end

    # Empty directories go too, so a purged conversation leaves no trace. Fails
    # harmlessly while anything is still staged.
    File.rmdir(dir)
    removed
  end

  # Payload files are counted; sidecars are removed alongside their payload, and
  # on their own only when the payload is already gone (a crashed stage).
  defp sweep_file(dir, name, cutoff) do
    path = Path.join(dir, name)

    cond do
      not stale?(path, cutoff) -> 0
      meta?(name) -> orphan_meta(dir, name, path)
      true -> sweep_payload(path)
    end
  end

  defp sweep_payload(path) do
    File.rm(meta_path(path))
    File.rm(path)
    1
  end

  defp orphan_meta(dir, name, path) do
    payload = String.replace_suffix(name, @meta_ext, "")

    siblings =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end

    if Enum.any?(siblings, &(&1 != name and String.starts_with?(&1, payload))) do
      0
    else
      File.rm(path)
      0
    end
  end

  defp stale?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < cutoff
      {:error, _reason} -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Attrs
  # ---------------------------------------------------------------------------

  defp source(attrs) do
    case pick(attrs, :source) do
      :upload -> {:ok, :upload}
      "upload" -> {:ok, :upload}
      :native_path -> {:ok, :native_path}
      "native_path" -> {:ok, :native_path}
      _other -> {:error, :invalid_source}
    end
  end

  # Atom keys and string keys both, so a decoded client payload and a hand-built
  # map go down one path instead of two that can disagree.
  defp pick(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
