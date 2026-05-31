defmodule BusterClaw.Markdown do
  @moduledoc """
  Renders local markdown into sanitized, blog-style HTML for previews.

  Frontmatter is stripped, Earmark produces the HTML, and HtmlSanitizeEx's
  markdown scrubber removes scripts, event handlers, and unsafe attributes.
  Workspace files can be authored by agents, so the output is **always**
  sanitized before it reaches the webview (CSP runs in report-only mode and
  cannot be relied on to block injected markup).
  """

  alias BusterClaw.Library.Frontmatter

  @doc "Render a markdown string to sanitized HTML, dropping any frontmatter."
  def to_html(markdown) when is_binary(markdown) do
    %{body: body} = Frontmatter.split(markdown)

    html =
      case Earmark.as_html(body, compact_output: true) do
        {:ok, html, _warnings} -> html
        {:error, html, _errors} -> html
      end

    HtmlSanitizeEx.markdown_html(html)
  end
end
