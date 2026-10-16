defmodule BusterClaw.Commands.Web.Bookmarks do
  @moduledoc "Bookmarks and browsing history — the `bookmark_*` and `history_*` verbs."
  # Split out of `BusterClaw.Commands.Web` on 10-16 (CODE_QUALITY_SWEEP Phase
  # 6); that module is the facade and the catalog's door.

  import BusterClaw.Commands.Helpers
  alias BusterClaw.BrowserHistory

  def bookmark_add(args) do
    url = Map.get(args, "url")
    label = Map.get(args, "label")
    tags = List.wrap(Map.get(args, "tags", []))
    folder = blank_to_nil(Map.get(args, "folder"))

    if url in [nil, ""] do
      {:error, :missing_url}
    else
      BusterClaw.Bookmarks.add(url, label, tags, folder)

      {:ok,
       %{
         url: url,
         label: label || url,
         tags: BusterClaw.Bookmarks.normalize_tags(tags),
         folder: BusterClaw.Bookmarks.normalize_folder(folder)
       }}
    end
  end

  def bookmark_list(args \\ %{}) do
    tag = blank_to_nil(Map.get(args, "tag"))
    tag_opts = if tag, do: [tag: tag], else: []
    folder_opts = if Map.has_key?(args, "folder"), do: [folder: Map.get(args, "folder")], else: []

    {:ok, BusterClaw.Bookmarks.list(tag_opts ++ folder_opts)}
  end

  def bookmark_remove(%{"url" => url}) do
    BusterClaw.Bookmarks.remove(url)
    {:ok, %{removed: url}}
  end

  def bookmark_remove(_args), do: {:error, :missing_url}

  def bookmark_export(args \\ %{}) do
    case Map.get(args, "format") do
      "html" -> {:ok, %{format: "html", content: BusterClaw.Bookmarks.export_html()}}
      _ -> {:ok, %{format: "json", content: BusterClaw.Bookmarks.export()}}
    end
  end

  def bookmark_import(args) do
    incoming = Map.get(args, "bookmarks") || Map.get(args, "json")

    case BusterClaw.Bookmarks.import(incoming) do
      {:ok, count} -> {:ok, %{imported: count}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------
  # Browsing history (read-only; recording happens in the desktop shell)
  # -----------------------------------------------------------------------

  def history_search(%{"query" => query} = args) when is_binary(query) do
    case BrowserHistory.search(query, limit: normalize_limit(Map.get(args, "limit"))) do
      {:ok, entries} -> {:ok, %{entries: Enum.map(entries, &history_entry/1)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def history_search(_args), do: {:error, :missing_query}

  def history_recent(args \\ %{}) do
    entries = BrowserHistory.recent(normalize_limit(Map.get(args, "limit")))
    {:ok, %{entries: Enum.map(entries, &history_entry/1)}}
  end

  defp history_entry(entry) do
    %{url: entry.url, title: entry.title, visited_at: entry.visited_at}
  end
end
