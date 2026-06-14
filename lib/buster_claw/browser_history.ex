defmodule BusterClaw.BrowserHistory do
  @moduledoc """
  Recent in-app browser destinations for the `/browse` homepage. File-backed per
  workspace (`<workspace>/.browser-history.json`); newest first, deduped by URL,
  capped. Records both external URLs and workspace files opened via the address
  bar (the native chrome toolbar posts each navigation here).
  """
  alias BusterClaw.Library.Artifact

  @filename ".browser-history.json"
  @max 50

  @doc "Absolute path of the per-workspace history file."
  def path, do: Path.join(Artifact.workspace_root(), @filename)

  @doc "Recent entries, newest first: `[%{\"url\" => ..., \"label\" => ..., \"at\" => ...}]`."
  def list do
    with {:ok, body} <- File.read(path()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      _ -> []
    end
  end

  @doc "Record a visited URL (with a display label), moving it to the top."
  def record(url, label \\ nil)

  def record(url, label) when is_binary(url) and url != "" do
    label = if is_binary(label) and String.trim(label) != "", do: label, else: url

    entry = %{
      "url" => url,
      "label" => label,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    updated =
      [entry | Enum.reject(list(), &(&1["url"] == url))]
      |> Enum.take(@max)

    File.write(path(), Jason.encode!(updated))
  end

  def record(_url, _label), do: :ok
end
