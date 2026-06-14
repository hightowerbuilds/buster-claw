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

  @doc "Saved bookmarks, newest first: `[%{\"url\" => ..., \"label\" => ..., \"at\" => ...}]`."
  def list do
    with {:ok, body} <- File.read(path()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      _ -> []
    end
  end

  @doc "Save a bookmark (with a display label), moving an existing match to the top."
  def add(url, label \\ nil)

  def add(url, label) when is_binary(url) and url != "" do
    label = if is_binary(label) and String.trim(label) != "", do: label, else: url

    entry = %{
      "url" => url,
      "label" => label,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    updated = [entry | Enum.reject(list(), &(&1["url"] == url))]
    File.write(path(), Jason.encode!(updated))
  end

  def add(_url, _label), do: :ok

  @doc "Remove the bookmark with the given URL."
  def remove(url) when is_binary(url) and url != "" do
    File.write(path(), Jason.encode!(Enum.reject(list(), &(&1["url"] == url))))
  end

  def remove(_url), do: :ok
end
