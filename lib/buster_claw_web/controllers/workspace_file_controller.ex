defmodule BusterClawWeb.WorkspaceFileController do
  @moduledoc """
  Serves a file from the workspace for the in-app browser: Markdown rendered to
  HTML, `.html`/`.htm` served as-is, other text wrapped in a `<pre>`. The path is
  validated to live inside the workspace via `FileManager.read_file/2` (traversal
  rejected, size-capped, binary rejected).

  Local-trust boundary: workspace files are operator/agent-authored, so `.html`
  is served verbatim (see `docs/LOCAL_TRUST.md`).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact

  @markdown_exts ~w(.md .markdown)
  @html_exts ~w(.html .htm)

  def show(conn, %{"path" => path}) when is_binary(path) and path != "" do
    workspace = Artifact.workspace_root()

    case FileManager.read_file(resolve(path, workspace), workspace) do
      {:ok, content} ->
        ext = path |> Path.extname() |> String.downcase()
        title = Path.basename(path)

        body =
          cond do
            ext in @markdown_exts -> document(title, BusterClaw.Markdown.to_html(content))
            ext in @html_exts -> content
            true -> document(title, "<pre>#{escape(content)}</pre>")
          end

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      {:error, :too_large} ->
        send_resp(conn, 413, "File is too large to display.")

      {:error, :binary} ->
        send_resp(conn, 415, "Binary file — cannot display.")

      {:error, :outside_base} ->
        send_resp(conn, 403, "That path is outside the workspace.")

      {:error, reason} ->
        send_resp(conn, 404, "Couldn't read file: #{inspect(reason)}")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "Missing ?path=")

  # Accept either an absolute path already inside the workspace, or a
  # workspace-relative path (leading `/` = workspace root), as the browser uses.
  defp resolve(path, workspace) do
    expanded = Path.expand(path)

    if FileManager.within?(expanded, workspace) do
      expanded
    else
      Path.expand(Path.join(workspace, String.trim_leading(path, "/")))
    end
  end

  # Minimal standalone document shell (the app's md-prose CSS isn't available
  # in this raw response, so inline just enough to make it readable).
  defp document(title, inner_html) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>#{escape(title)}</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 46rem;
             margin: 2.5rem auto; padding: 0 1.25rem; }
      pre { white-space: pre-wrap; word-break: break-word; background: rgba(127,127,127,.12);
            padding: 1rem; border-radius: 6px; font: 13px/1.5 ui-monospace, monospace; }
      code { font-family: ui-monospace, monospace; }
      img, table { max-width: 100%; }
      a { color: #ff4d1c; }
    </style>
    </head>
    <body>#{inner_html}</body>
    </html>
    """
  end

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
