defmodule BusterClawWeb.BrowserWorkspaceController do
  @moduledoc """
  Workspace file browser shown in the content webview when the address bar starts
  with `/`. Lists the folders/files under a workspace-relative path (the leading
  `/` is the workspace root), filtered by the trailing name. Folders drill in
  (link back here); files open via `/ws/file`. Dark-themed to match.

  The markup lives in `BusterClawWeb.Browser.WorkspaceIndex`; this resolves the
  path and does the listing.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact
  alias BusterClawWeb.Browser.WorkspaceIndex

  def show(conn, params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, WorkspaceIndex.html(listing(params["q"] || "/")))
  end

  defp listing(q) do
    ws = Artifact.workspace_root()
    {dir, prefix} = split(q)

    entries =
      case FileManager.list(abs_of(ws, dir), ws) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&prefix_match?(&1.name, prefix))
          |> Enum.map(&%{name: &1.name, type: &1.type, rel: rel_of(ws, &1.path)})

        {:error, _reason} ->
          :error
      end

    %{dir: dir, entries: entries, parent: if(dir != "/", do: parent_dir(dir))}
  end

  # "/library/no" -> {"/library", "no"}; "/library/" -> {"/library", ""}; "/" -> {"/", ""}.
  defp split(q) do
    q = if String.starts_with?(q, "/"), do: q, else: "/" <> q

    if String.ends_with?(q, "/") do
      {q |> String.trim_trailing("/") |> root_if_empty(), ""}
    else
      {Path.dirname(q), Path.basename(q)}
    end
  end

  defp root_if_empty(""), do: "/"
  defp root_if_empty(dir), do: dir

  defp parent_dir(dir) do
    case Path.dirname(dir) do
      "." -> "/"
      parent -> parent
    end
  end

  defp abs_of(ws, "/"), do: ws
  defp abs_of(ws, "/" <> rest), do: Path.join(ws, rest)
  defp abs_of(ws, rest), do: Path.join(ws, rest)

  defp rel_of(ws, abs), do: "/" <> Path.relative_to(abs, ws)

  defp prefix_match?(_name, ""), do: true

  defp prefix_match?(name, prefix),
    do: String.starts_with?(String.downcase(name), String.downcase(prefix))
end
