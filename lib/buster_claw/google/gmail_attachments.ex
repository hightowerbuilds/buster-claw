defmodule BusterClaw.Google.GmailAttachments do
  @moduledoc """
  Saves a Gmail message's attachments into the workspace — the one place inbound
  attachment bytes touch disk.

  `BusterClaw.Google.Gmail.Parts` lists what a message carries (metadata only),
  `fetch_bytes/4` resolves one entry to bytes, and `save/3` turns the list into
  files the agent can open: `attachments/gmail/<message-id>/<name>`
  under the workspace root by default. Both callers — the
  `gmail_attachment_download` command and `GmailSync` (trusted senders only) —
  go through `save/3`, so the fence, the size cap, and the filename rules are
  defined once.

  Three rules, mirrors of the outbound fence in `Gmail.Mime`:

    * **Destination inside the workspace.** A caller-supplied `:destination` is
      resolved and checked with `BusterClaw.FileManager.within?/2` (canonicalizes
      through symlinks). Outside → `{:error, {:destination_outside_workspace, abs}}`
      before any byte is fetched.
    * **Filenames are display data, never paths.** The sender chose the name;
      it is reduced to a safe basename (`sanitize/1`), and a missing name gets a
      generated one from the part's MIME type. Same-name collisions inside one
      message get a numeric suffix rather than overwriting each other.
    * **A size cap.** Gmail's own ceiling is 25 MB per message; anything the
      parsed metadata declares above `max_bytes/0`, or that arrives larger, is
      skipped and reported, never written.
  """

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Google.Gmail.Parts
  alias BusterClaw.Library.Artifact

  @default_root "attachments/gmail"
  @max_bytes 25 * 1024 * 1024

  @type saved :: %{
          filename: String.t(),
          path: String.t(),
          absolute_path: String.t(),
          mime_type: String.t() | nil,
          bytes: non_neg_integer(),
          attachment_id: String.t() | nil,
          part_id: String.t() | nil
        }

  @doc "Per-file cap in bytes."
  def max_bytes, do: @max_bytes

  @doc "Default workspace-relative directory for a message's attachments."
  def default_dir(message_id) do
    Path.join(@default_root, safe_segment(message_id))
  end

  @doc """
  Save `message.attachments` (or `opts[:select]`, a subset of them) to disk.

  Options:

    * `:destination` — directory, workspace-relative or absolute, fenced to the
      workspace. Defaults to `default_dir(message.id)`.
    * `:select` — the attachment entries to save (default: all of them).
    * anything else is passed to the Gmail client (`:req_options`, …).

  Returns `{:ok, %{saved: [saved], skipped: [...], errors: [...]}}`. A single
  attachment failing to download does not fail its siblings — it lands in
  `errors` with its reason — but a destination outside the workspace is refused
  up front.
  """
  @spec save(Account.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def save(%Account{} = account, message, opts \\ []) do
    attachments = Keyword.get(opts, :select) || Map.get(message, :attachments) || []
    client_opts = Keyword.drop(opts, [:destination, :select])

    with {:ok, dir} <- resolve_destination(Keyword.get(opts, :destination), message.id) do
      {saved, skipped, errors, _names} =
        attachments
        |> Enum.with_index(1)
        |> Enum.reduce({[], [], [], MapSet.new()}, fn {attachment, index},
                                                      {saved, skipped, errors, names} ->
          filename = unique_name(target_name(attachment, index), names)
          names = MapSet.put(names, filename)

          case save_one(account, message, attachment, dir, filename, client_opts) do
            {:ok, entry} -> {[entry | saved], skipped, errors, names}
            {:skip, entry} -> {saved, [entry | skipped], errors, names}
            {:error, entry} -> {saved, skipped, [entry | errors], names}
          end
        end)

      {:ok,
       %{
         message_id: message.id,
         directory: relative(dir),
         saved: Enum.reverse(saved),
         skipped: Enum.reverse(skipped),
         errors: Enum.reverse(errors)
       }}
    end
  end

  @doc """
  Pick attachments from a parsed message by `attachment_id`, `filename`, or
  1-based `index`. With none of those, every attachment is selected.
  """
  def select(message, selector) when is_map(selector) do
    attachments = Map.get(message, :attachments) || []

    cond do
      id = present(Map.get(selector, "attachment_id")) ->
        Enum.filter(attachments, &(&1.attachment_id == id))

      name = present(Map.get(selector, "filename")) ->
        Enum.filter(attachments, &(&1.filename == name))

      index = parse_index(Map.get(selector, "index")) ->
        attachments |> Enum.at(index - 1) |> List.wrap()

      true ->
        attachments
    end
  end

  @doc """
  Resolve the bytes of one entry from a parsed message's `attachments` list:
  an id'd attachment is fetched (`Gmail.attachment/4`); one Gmail inlined as
  `body.data` is decoded out of the raw message with no extra round trip.
  """
  def fetch_bytes(account, message, attachment, opts \\ [])

  def fetch_bytes(%Account{} = account, message, %{attachment_id: id}, opts)
      when is_binary(id) and id != "" do
    Gmail.attachment(account, message.id, id, opts)
  end

  def fetch_bytes(_account, message, %{part_id: part_id}, _opts) do
    case Parts.inline_attachment_data(Map.get(message, :raw), part_id) do
      nil -> {:error, {:attachment_empty, part_id}}
      data -> {:ok, data}
    end
  end

  @doc "Reduce a sender-supplied filename to a safe basename."
  def sanitize(name) do
    cleaned =
      name
      |> to_string()
      |> Path.basename()
      |> String.replace(~r/[^\w.\-]+/u, "_")
      |> String.trim("_")

    if cleaned in ["", ".", ".."], do: nil, else: cleaned
  end

  # --- internals -----------------------------------------------------------

  defp save_one(account, message, attachment, dir, filename, client_opts) do
    declared = Map.get(attachment, :size)
    base = %{filename: filename, mime_type: Map.get(attachment, :mime_type)}

    if is_integer(declared) and declared > @max_bytes do
      {:skip, Map.merge(base, %{reason: :too_large, bytes: declared})}
    else
      case fetch_bytes(account, message, attachment, client_opts) do
        {:ok, data} when byte_size(data) > @max_bytes ->
          {:skip, Map.merge(base, %{reason: :too_large, bytes: byte_size(data)})}

        {:ok, data} ->
          write(dir, filename, data, attachment)

        {:error, reason} ->
          {:error, Map.put(base, :reason, reason)}
      end
    end
  end

  defp write(dir, filename, data, attachment) do
    abs = Path.join(dir, filename)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(abs, data) do
      {:ok,
       %{
         filename: filename,
         path: relative(abs),
         absolute_path: abs,
         mime_type: Map.get(attachment, :mime_type),
         bytes: byte_size(data),
         attachment_id: Map.get(attachment, :attachment_id),
         part_id: Map.get(attachment, :part_id)
       }}
    else
      {:error, reason} ->
        {:error,
         %{filename: filename, mime_type: Map.get(attachment, :mime_type), reason: reason}}
    end
  end

  defp resolve_destination(destination, message_id) do
    root = Artifact.workspace_root()

    target =
      case present(destination) do
        nil -> Path.join(root, default_dir(message_id))
        path -> expand(path, root)
      end

    if BusterClaw.FileManager.within?(target, root) do
      {:ok, target}
    else
      {:error, {:destination_outside_workspace, target}}
    end
  end

  defp expand(path, root) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _relative -> Path.expand(path, root)
    end
  end

  defp relative(abs) do
    root = Artifact.workspace_root()

    case Path.relative_to(abs, root) do
      ^abs -> abs
      rel -> rel
    end
  end

  defp target_name(attachment, index) do
    sanitize(Map.get(attachment, :filename)) ||
      "attachment-#{index}" <> extension_for(Map.get(attachment, :mime_type))
  end

  defp unique_name(name, names) do
    if MapSet.member?(names, name) do
      ext = Path.extname(name)
      stem = Path.basename(name, ext)

      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{stem}-#{n}#{ext}"
        if MapSet.member?(names, candidate), do: nil, else: candidate
      end)
    else
      name
    end
  end

  defp extension_for(mime_type) do
    case mime_type do
      "image/png" -> ".png"
      "image/jpeg" -> ".jpg"
      "image/gif" -> ".gif"
      "image/webp" -> ".webp"
      "image/heic" -> ".heic"
      "application/pdf" -> ".pdf"
      "text/plain" -> ".txt"
      "text/csv" -> ".csv"
      _other -> ".bin"
    end
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> case do
      "" -> "message"
      segment -> segment
    end
  end

  defp parse_index(nil), do: nil
  defp parse_index(value) when is_integer(value) and value > 0, do: value

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  defp parse_index(_value), do: nil

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value
end
