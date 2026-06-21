defmodule BusterClaw.Bookmarks do
  @moduledoc """
  Saved in-app browser bookmarks for the `/browser/home` page. File-backed per
  workspace (`<workspace>/.browser-bookmarks.json`); newest first, deduped by URL.
  The native chrome toolbar's "+ Bookmark" button posts the current page here;
  the homepage renders them above the recent-URL list and removes them via a form.
  """
  alias BusterClaw.Library.Artifact

  @filename ".browser-bookmarks.json"

  @doc "Absolute path of the per-workspace bookmarks file."
  def path, do: Path.join(Artifact.workspace_root(), @filename)

  @doc "Saved bookmarks, newest first. Pass `tag:` to filter."
  def list(opts \\ []) do
    entries =
      with {:ok, body} <- File.read(path()),
           {:ok, entries} when is_list(entries) <- Jason.decode(body) do
        entries
      else
        _ -> []
      end

    case Keyword.get(opts, :tag) do
      nil -> entries
      tag -> Enum.filter(entries, &(tag in List.wrap(&1["tags"])))
    end
  end

  @doc "Save a bookmark (with a display label and optional tags), moving an existing match to the top."
  def add(url, label \\ nil, tags \\ [])

  def add(url, label, tags) when is_binary(url) and url != "" do
    label = if is_binary(label) and String.trim(label) != "", do: label, else: url

    entry = %{
      "url" => url,
      "label" => label,
      "tags" => normalize_tags(tags),
      "favicon_url" => favicon_url(url),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    updated = [entry | Enum.reject(list(), &(&1["url"] == url))]
    File.write(path(), Jason.encode!(updated))
  end

  def add(_url, _label, _tags), do: :ok

  @doc "Remove the bookmark with the given URL."
  def remove(url) when is_binary(url) and url != "" do
    File.write(path(), Jason.encode!(Enum.reject(list(), &(&1["url"] == url))))
  end

  def remove(_url), do: :ok

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

  @doc """
  Best-effort favicon URL for a page. Returns Google's public favicon service
  URL keyed by host (it serves a sensible globe fallback when a site has none),
  or `nil` when the URL has no resolvable host. We store the URL, not the bytes;
  the webview fetches it lazily when rendering the homepage.
  """
  def favicon_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        "https://www.google.com/s2/favicons?domain=#{host}&sz=64"

      _ ->
        nil
    end
  end

  def favicon_url(_), do: nil
end
