defmodule BusterClaw.Bookmarks do
  @moduledoc """
  Saved in-app browser bookmarks for the `/browser/home` page. File-backed per
  workspace (`<workspace>/.browser-bookmarks.json`); newest first, deduped by URL.
  The native chrome toolbar's "+ Bookmark" button posts the current page here;
  the homepage renders them above the recent-URL list and removes them via a form.

  Each entry is a map with `url`, `label`, `tags` (list), `folder` (string or
  `nil` = root), and `at`. Older flat files written before folders existed (no
  `folder` key) load fine and render at the root. Favicons are not stored —
  renderers derive them per-URL via `favicon_url/1` (older files that carry a
  stored `favicon_url`, including the retired Google s2 URLs, are ignored).
  """
  alias BusterClaw.Library.Artifact

  @filename ".browser-bookmarks.json"

  @doc "Absolute path of the per-workspace bookmarks file."
  def path, do: Artifact.workspace_path(@filename)

  @doc """
  Saved bookmarks, newest first. Options:

    * `:tag` — keep only bookmarks carrying this tag.
    * `:folder` — keep only bookmarks in this folder (`nil`/`""` = root).
  """
  def list(opts \\ []) do
    entries = read_all()

    entries =
      case Keyword.get(opts, :tag) do
        nil -> entries
        tag -> Enum.filter(entries, &(tag in List.wrap(&1["tags"])))
      end

    case Keyword.fetch(opts, :folder) do
      :error -> entries
      {:ok, folder} -> Enum.filter(entries, &(folder_of(&1) == normalize_folder(folder)))
    end
  end

  @doc """
  Bookmarks grouped by folder: a list of `{folder, entries}` tuples with the
  root group (`nil`) first, then named folders A→Z. Each group keeps the
  newest-first order. Accepts the same options as `list/1`.
  """
  def grouped(opts \\ []), do: group(list(opts))

  @doc """
  Group an already-loaded list of bookmarks by folder (root first, folders A→Z).
  Lets callers group without re-reading the file.
  """
  def group(entries) when is_list(entries) do
    groups = Enum.group_by(entries, &folder_of/1)
    root = Map.get(groups, nil, [])

    named =
      groups
      |> Map.delete(nil)
      |> Enum.sort_by(fn {folder, _} -> String.downcase(folder) end)

    root_group = if root == [], do: [], else: [{nil, root}]
    root_group ++ named
  end

  @doc "Save a bookmark (display label, optional tags, optional folder), moving an existing match to the top."
  def add(url, label \\ nil, tags \\ [], folder \\ nil)

  def add(url, label, tags, folder) when is_binary(url) and url != "" do
    label = if is_binary(label) and String.trim(label) != "", do: label, else: url

    entry = %{
      "url" => url,
      "label" => label,
      "tags" => normalize_tags(tags),
      "folder" => normalize_folder(folder),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    updated = [entry | Enum.reject(read_all(), &(&1["url"] == url))]
    File.write(path(), Jason.encode!(updated))
  end

  def add(_url, _label, _tags, _folder), do: :ok

  @doc "Remove the bookmark with the given URL."
  def remove(url) when is_binary(url) and url != "" do
    File.write(path(), Jason.encode!(Enum.reject(read_all(), &(&1["url"] == url))))
  end

  def remove(_url), do: :ok

  # ---------------------------------------------------------------------------
  # Import / export
  # ---------------------------------------------------------------------------

  @doc "All bookmarks as a pretty-printed JSON string (portable, git-diffable backup)."
  def export, do: Jason.encode!(list(), pretty: true)

  @doc """
  All bookmarks as a Netscape bookmark-file HTML string — the portable format
  browsers import/export. Bookmarks are grouped into `<H3>` folders (root entries
  first). Tags ride along in a `TAGS` attribute for round-trips with tools that
  understand it.
  """
  def export_html do
    sections =
      list()
      |> group()
      |> Enum.map_join("", fn
        {nil, items} -> Enum.map_join(items, "", &netscape_link/1)
        {folder, items} -> netscape_folder(folder, items)
      end)

    """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
    #{sections}</DL><p>
    """
  end

  @doc """
  Merge an incoming bookmark list (a list of maps, or a JSON string of one) into
  the store. Deduped by URL: existing entries keep their position and their
  filing — tags are unioned, and an imported folder only fills a blank one (an
  existing non-blank folder is preserved); new URLs are appended. Returns
  `{:ok, count}` or `{:error, :invalid}`.
  """
  def import(incoming) when is_binary(incoming) do
    case Jason.decode(incoming) do
      {:ok, list} when is_list(list) -> import_list(list)
      _ -> {:error, :invalid}
    end
  end

  def import(incoming) when is_list(incoming), do: import_list(incoming)

  def import(_), do: {:error, :invalid}

  defp import_list(incoming) do
    merged = merge_entries(read_all(), incoming)
    File.write(path(), Jason.encode!(merged))
    {:ok, length(merged)}
  end

  # ---------------------------------------------------------------------------
  # Tags / folders
  # ---------------------------------------------------------------------------

  @doc "Normalize tags to a list of downcased, trimmed, unique strings."
  def normalize_tags(nil), do: []

  def normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(fn t ->
      t |> to_string() |> String.trim() |> String.downcase()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_tags(tag) when is_binary(tag) do
    tag |> String.split(",") |> normalize_tags()
  end

  def normalize_tags(_), do: []

  @doc "Normalize a folder name to a trimmed string, or `nil` for the root (blank/missing)."
  def normalize_folder(nil), do: nil

  def normalize_folder(folder) when is_binary(folder) do
    case String.trim(folder) do
      "" -> nil
      f -> f
    end
  end

  def normalize_folder(_), do: nil

  @doc """
  Best-effort favicon URL for a page: the local `/browser/favicon` endpoint
  keyed by host (served from `BusterClaw.Favicons`' disk cache), or `nil` when
  the URL has no resolvable host. Relative on purpose — every consumer (the
  chrome, the homepage, the bookmark-bar JSON) renders on the Phoenix origin,
  and visited hosts never leave the machine.
  """
  def favicon_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        "/browser/favicon?host=#{URI.encode_www_form(host)}"

      _ ->
        nil
    end
  end

  def favicon_url(_), do: nil

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp read_all do
    with {:ok, body} <- File.read(path()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      _ -> []
    end
  end

  defp folder_of(entry), do: normalize_folder(entry["folder"])

  defp merge_entries(existing, incoming) do
    incoming =
      incoming
      |> Enum.filter(&valid_entry?/1)
      |> Enum.map(&normalize_entry/1)

    incoming_by_url = Map.new(incoming, &{&1["url"], &1})
    existing_urls = MapSet.new(existing, & &1["url"])

    merged_existing =
      Enum.map(existing, fn e ->
        case Map.get(incoming_by_url, e["url"]) do
          nil -> e
          inc -> merge_pair(e, inc)
        end
      end)

    new_ones =
      incoming
      |> Enum.reject(&MapSet.member?(existing_urls, &1["url"]))
      |> Enum.uniq_by(& &1["url"])

    merged_existing ++ new_ones
  end

  defp merge_pair(existing, incoming) do
    existing
    |> Map.put("tags", normalize_tags(List.wrap(existing["tags"]) ++ List.wrap(incoming["tags"])))
    |> Map.put(
      "folder",
      normalize_folder(existing["folder"]) || normalize_folder(incoming["folder"])
    )
    |> Map.put("label", existing["label"] || incoming["label"])
  end

  defp valid_entry?(%{"url" => url}) when is_binary(url) and url != "", do: true
  defp valid_entry?(_), do: false

  defp normalize_entry(%{"url" => url} = m) do
    %{
      "url" => url,
      "label" => entry_label(m["label"], url),
      "tags" => normalize_tags(m["tags"]),
      "folder" => normalize_folder(m["folder"]),
      "at" => m["at"] || DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp entry_label(label, url) do
    if is_binary(label) and String.trim(label) != "", do: label, else: url
  end

  defp netscape_folder(folder, items) do
    links = Enum.map_join(items, "", &netscape_link/1)

    """
    <DT><H3>#{html_escape(folder)}</H3>
    <DL><p>
    #{links}</DL><p>
    """
  end

  defp netscape_link(entry) do
    tags = entry |> Map.get("tags") |> List.wrap() |> Enum.join(",")
    tags_attr = if tags == "", do: "", else: ~s( TAGS="#{html_escape(tags)}")
    date_attr = netscape_date(entry["at"])
    label = entry["label"] || entry["url"]

    ~s(<DT><A HREF="#{html_escape(entry["url"])}"#{date_attr}#{tags_attr}>#{html_escape(label)}</A>\n)
  end

  defp netscape_date(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> ~s( ADD_DATE="#{DateTime.to_unix(dt)}")
      _ -> ""
    end
  end

  defp netscape_date(_), do: ""

  defp html_escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
