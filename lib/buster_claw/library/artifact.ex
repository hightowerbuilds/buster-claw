defmodule BusterClaw.Library.Artifact do
  @moduledoc "Filesystem boundary for local markdown Library artifacts."

  alias BusterClaw.Library.Frontmatter
  alias BusterClaw.LocalTime

  @raw_dir "raw"
  @reports_dir "reports"
  @max_excerpt 280

  @workspace_subdirs ~w(sources analysis memory)

  def root do
    Application.fetch_env!(:buster_claw, :library_root)
  end

  @doc """
  The workspace folder that contains the `library/` directory (= `root/0`) plus
  the `sources/`, `analysis/`, and `memory/` siblings. Defaults to the parent of
  the library root when `:workspace_root` is unset (e.g. in tests that only
  override `:library_root`).
  """
  def workspace_root do
    case Application.get_env(:buster_claw, :workspace_root) do
      nil -> Path.dirname(Path.expand(root()))
      value -> Path.expand(value)
    end
  end

  @doc "Names of the workspace sub-directories scaffolded alongside `library/`."
  def workspace_subdirs, do: @workspace_subdirs

  def ensure_directories do
    File.mkdir_p!(raw_root())
    File.mkdir_p!(reports_root())
    :ok
  end

  @doc """
  Create the full workspace layout: the library tree (`raw/`, `reports/`) plus
  the `sources/`, `analysis/`, and `memory/` sibling directories. The latter
  three are organizational scaffolding today (those domains are DB-backed) and
  are reserved for file exports.
  """
  def ensure_workspace_dirs do
    ensure_directories()

    workspace = workspace_root()

    Enum.each(@workspace_subdirs, fn sub ->
      File.mkdir_p!(Path.join(workspace, sub))
    end)

    :ok
  end

  def raw_date_dir(%Date{} = date) do
    Path.join([root(), @raw_dir, Date.to_iso8601(date)])
  end

  def write_raw_document(attrs) when is_map(attrs) do
    ensure_directories()

    date = date_attr(attrs) || LocalTime.today()
    filename = attrs |> attr(:filename) |> fallback_filename(attrs) |> markdown_filename()
    dir = raw_date_dir(date)
    path = safe_join!(dir, [filename])
    :ok = File.mkdir_p!(dir)

    content = attr(attrs, :content) || attr(attrs, :body) || ""

    fields = %{
      "url" => attr(attrs, :source_url),
      "name" => attr(attrs, :name),
      "tags" => normalize_tags(attr(attrs, :tags)),
      "fetched_at" => attr(attrs, :fetched_at)
    }

    body = String.trim_leading(to_string(content))
    bytes = Frontmatter.build(fields) <> body

    File.write!(path, bytes)

    # Reuse the rendered bytes/body for downstream metadata instead of forcing a
    # re-read + re-parse from disk. `split/1` of `bytes` would yield the same
    # parsed fields, but we already hold them here.
    parsed_fields = Frontmatter.split(bytes).fields

    {:ok,
     %{
       path: path,
       content: bytes,
       fields: parsed_fields,
       content_hash: body_hash(body),
       excerpt: excerpt(body)
     }}
  end

  def parse_markdown_file(path) do
    with {:ok, content} <- File.read(path) do
      split = Frontmatter.split(content)

      {:ok,
       %{
         fields: split.fields,
         body: split.body,
         # Hash the body (not the full file) so the hash is stable across
         # re-renders whose frontmatter varies (e.g. `fetched_at`). This lets
         # dedupe compare bodies via the stored hash without reading the file.
         content_hash: body_hash(split.body),
         excerpt: excerpt(split.body)
       }}
    end
  end

  def read_raw_document(path) do
    with {:ok, abs_path} <- validate_raw_path(path),
         {:ok, parsed} <- parse_markdown_file(abs_path) do
      {:ok, parsed.body}
    end
  end

  def delete_raw_document(path) do
    with {:ok, abs_path} <- validate_raw_path(path) do
      case File.rm(abs_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def validate_raw_path(path) when is_binary(path) do
    abs_path = absolute_path(path)
    raw = raw_root()

    cond do
      not inside?(abs_path, raw) ->
        {:error, :outside_library}

      Path.extname(abs_path) != ".md" ->
        {:error, :invalid_artifact}

      true ->
        {:ok, abs_path}
    end
  end

  def relative_to_root(path) do
    abs_path = Path.expand(path)
    root = Path.expand(root())

    if abs_path == root do
      "."
    else
      abs_path
      |> String.replace_prefix(root <> "/", "")
    end
  end

  def safe_join!(base, segments) when is_list(segments) do
    base = Path.expand(base)
    path = Path.expand(Path.join([base | segments]))

    if inside?(path, root()) do
      path
    else
      raise ArgumentError, "artifact path escapes library root"
    end
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp date_attr(attrs) do
    case attr(attrs, :date) do
      %Date{} = date ->
        date

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _reason} -> nil
        end

      _ ->
        nil
    end
  end

  defp fallback_filename(nil, attrs),
    do: attr(attrs, :name) || attr(attrs, :source_url) || "document"

  defp fallback_filename("", attrs), do: fallback_filename(nil, attrs)
  defp fallback_filename(filename, _attrs), do: filename

  defp markdown_filename(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> slug()
    |> Kernel.<>(".md")
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "document"
      slug -> slug
    end
  end

  defp normalize_tags(nil), do: []
  defp normalize_tags(%{"items" => items}), do: List.wrap(items)
  defp normalize_tags(%{items: items}), do: List.wrap(items)
  defp normalize_tags(tags), do: List.wrap(tags)

  defp absolute_path(path) do
    expanded = Path.expand(path)

    if inside?(expanded, root()) do
      expanded
    else
      Path.expand(path, root())
    end
  end

  defp raw_root, do: Path.join(root(), @raw_dir) |> Path.expand()
  defp reports_root, do: Path.join(root(), @reports_dir) |> Path.expand()

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  @doc """
  The content hash stored on a document: the sha256 of its trimmed body. Used
  by dedupe to compare bodies without reading the artifact back off disk.
  """
  def body_hash(body), do: body |> to_string() |> String.trim() |> content_hash()

  defp content_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp excerpt(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_excerpt)
  end
end
