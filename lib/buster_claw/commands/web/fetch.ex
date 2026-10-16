defmodule BusterClaw.Commands.Web.Fetch do
  @moduledoc "Fetching without a visible tab — `web_search`, `browser_fetch`, `browser_download`."
  # Split out of `BusterClaw.Commands.Web` on 10-16 (CODE_QUALITY_SWEEP Phase
  # 6); that module is the facade and the catalog's door.

  import BusterClaw.Commands.Helpers
  alias BusterClaw.{Browser, Search}

  def web_search(%{"query" => query} = args) do
    limit = Map.get(args, "limit", 10)
    Search.search(query, limit: limit)
  end

  # -----------------------------------------------------------------------
  # Browser
  # -----------------------------------------------------------------------

  def browser_fetch(%{"url" => url} = args), do: Browser.fetch(url, render: render_mode(args))

  # "live" forces the desktop shell's hidden-webview render; "off" forbids it;
  # anything else lets Browser.fetch upgrade automatically when the plain
  # pipeline comes back JS-thin.
  defp render_mode(args) do
    case Map.get(args, "render") do
      "live" -> :live
      "off" -> :off
      _other -> :auto
    end
  end

  def browser_download(%{"url" => url} = args) when is_binary(url) and url != "" do
    with {:ok, dl} <- Browser.download(url) do
      filename = sanitize_download_name(Map.get(args, "filename") || dl.filename)
      rel = Path.join(["downloads", Date.to_iso8601(BusterClaw.LocalTime.today()), filename])
      abs = resolve_workspace_path(rel)

      with :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, dl.body) do
        {:ok,
         %{
           path: rel,
           absolute_path: abs,
           url: url,
           content_type: dl.content_type,
           bytes: byte_size(dl.body)
         }}
      end
    end
  end

  def browser_download(_args), do: {:error, :missing_url}
end
