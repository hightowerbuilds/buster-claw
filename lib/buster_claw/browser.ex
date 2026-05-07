defmodule BusterClaw.Browser do
  @moduledoc "Browser-rendered fetch boundary with an HTTP fallback until the sidecar is packaged."

  alias BusterClaw.Ingest.Content

  @user_agent "BusterClaw/2.0 BrowserSidecarFallback"

  def fetch(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    request_options =
      [
        headers: [{"user-agent", @user_agent}, {"accept", "text/html,*/*;q=0.8"}],
        receive_timeout: timeout,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:buster_claw, :browser_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.get(url, request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        html = to_string(body)

        {:ok,
         %{
           url: url,
           title: Content.html_title(html) || URI.parse(url).host || url,
           html: html,
           markdown: Content.html_to_markdown(html)
         }}

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def status do
    %{
      mode: "http-fallback",
      sidecar: "not-started",
      health: "available"
    }
  end
end
