defmodule BusterClawWeb.BrowserWorkspaceController do
  @moduledoc """
  Workspace file browser shown in the content webview when the address bar starts
  with `/`. Lists the folders/files under a workspace-relative path (the leading
  `/` is the workspace root), filtered by the trailing name. Folders drill in
  (link back here); files open via `/ws/file`. Dark-themed to match.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact

  def show(conn, params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(params["q"] || "/"))
  end

  defp page(q) do
    ws = Artifact.workspace_root()
    {dir, prefix} = split(q)
    abs_dir = abs_of(ws, dir)

    listing =
      case FileManager.list(abs_dir, ws) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&prefix_match?(&1.name, prefix))
          |> rows(ws, dir)

        {:error, _} ->
          ~s(<p class="empty">That folder isn't in the workspace.</p>)
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Workspace</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; }
      body { background: #121212; color: #f4f1ea; padding: 32px 28px;
             font: 15px/1.5 -apple-system, system-ui, sans-serif; }
      .eyebrow { font: 700 11px/1 ui-monospace, monospace; letter-spacing: .12em;
                 text-transform: uppercase; color: rgba(244,241,234,.5); }
      h1 { margin: 6px 0 20px; font: 700 18px/1.3 ui-monospace, monospace; word-break: break-all; }
      ul { list-style: none; margin: 0; padding: 0; max-width: 52rem; }
      li { border-top: 1px solid rgba(244,241,234,.12); }
      a { display: flex; align-items: center; gap: 10px; padding: 10px 4px;
          color: #f4f1ea; text-decoration: none; }
      a:hover { color: #ff4d1c; }
      .ico { flex: 0 0 1.2em; opacity: .6; }
      .empty { color: rgba(244,241,234,.55); }
    </style>
    </head>
    <body>
      <p class="eyebrow">Workspace</p>
      <h1>#{escape(dir)}</h1>
      #{listing}
      <script>
        // Record opened files into the browser history (fires during navigation).
        document.addEventListener("click", function (e) {
          var a = e.target.closest("a[data-file]")
          if (!a) return
          try {
            navigator.sendBeacon("/browser/history?url=" + encodeURIComponent(a.getAttribute("href")) +
              "&label=" + encodeURIComponent(a.getAttribute("data-label")))
          } catch (_e) {}
        })
      </script>
    </body>
    </html>
    """
  end

  defp rows(entries, ws, dir) do
    parent =
      if dir != "/" do
        ~s(<li><a href="/browser/workspace?q=#{enc(parent_dir(dir))}"><span class="ico">&#8617;</span>..</a></li>)
      else
        ""
      end

    items =
      Enum.map_join(entries, "\n", fn e ->
        rel = rel_of(ws, e.path)

        if e.type == :dir do
          ~s(<li><a href="/browser/workspace?q=#{enc(rel <> "/")}"><span class="ico">&#128193;</span>#{escape(e.name)}</a></li>)
        else
          ~s(<li><a data-file data-label="#{escape(rel)}" href="/ws/file?path=#{enc(rel)}"><span class="ico">&#128196;</span>#{escape(e.name)}</a></li>)
        end
      end)

    body = parent <> "\n" <> items

    if String.trim(items) == "",
      do: parent <> ~s(<p class="empty">Empty folder.</p>),
      else: "<ul>#{body}</ul>"
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

  defp enc(value), do: URI.encode_www_form(to_string(value))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
