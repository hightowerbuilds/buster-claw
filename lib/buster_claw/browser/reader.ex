defmodule BusterClaw.Browser.Reader do
  @moduledoc """
  Turns fetched HTML into a safe, link-aware token stream for the in-app browser.

  The output is an ordered list of `{:text, binary}` and `{:link, text, url}`
  tokens. No raw HTML is ever emitted — callers render text and links with
  ordinary auto-escaped HEEx, so a fetched page cannot inject markup or scripts.
  Anchors are resolved to absolute http(s) URLs against the page's own URL so
  that clicking a link can re-fetch it through the (SSRF-guarded) browser
  boundary and keep the user inside the app.
  """

  @anchor ~r/<a\b[^>]*?href=["']([^"']*)["'][^>]*?>(.*?)<\/a>/is

  @type token :: {:text, String.t()} | {:link, String.t(), String.t()}

  @spec to_tokens(String.t(), String.t()) :: [token()]
  def to_tokens(html, base_url) when is_binary(html) do
    html
    |> preclean()
    |> split_anchors(base_url)
    |> Enum.reject(&empty_token?/1)
  end

  def to_tokens(_html, _base_url), do: []

  defp preclean(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<noscript\b[^>]*>.*?<\/noscript>/is, " ")
    |> String.replace(~r/<head\b[^>]*>.*?<\/head>/is, " ")
    |> String.replace(~r/<\s*br\s*\/?\s*>/i, "\n")
    |> String.replace(~r/<\/\s*(p|div|section|article|header|footer|li|tr|h[1-6])\s*>/i, "\n\n")
  end

  defp split_anchors(html, base_url) do
    @anchor
    |> Regex.split(html, include_captures: true)
    |> Enum.map(&classify(&1, base_url))
  end

  defp classify(chunk, base_url) do
    case Regex.run(@anchor, chunk) do
      [_full, href, inner] ->
        text = clean_text(inner)

        case absolute_http(href, base_url) do
          {:ok, url} -> {:link, link_text(text, url), url}
          # Non-fetchable (mailto:, javascript:, #anchor) → keep the text only.
          :error -> {:text, text}
        end

      _ ->
        {:text, clean_text(chunk)}
    end
  end

  defp absolute_http(href, base_url) do
    href = String.trim(href)

    cond do
      href == "" -> :error
      String.starts_with?(href, "#") -> :error
      String.match?(href, ~r/^(javascript|mailto|tel|data):/i) -> :error
      true -> merge_http(href, base_url)
    end
  end

  defp merge_http(href, base_url) do
    merged = base_url |> URI.parse() |> URI.merge(href) |> URI.to_string()

    case URI.parse(merged) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> {:ok, merged}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp link_text(text, url) do
    case String.trim(text) do
      "" -> url
      trimmed -> trimmed
    end
  end

  defp clean_text(value) do
    value
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> collapse_whitespace()
  end

  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
  end

  defp collapse_whitespace(text) do
    text
    # collapse runs of spaces/tabs, but preserve newlines
    |> String.replace(~r/[ \t]+/, " ")
    # collapse 3+ newlines down to a paragraph break
    |> String.replace(~r/\n[ \t]*\n[ \t\n]*/, "\n\n")
    |> String.trim()
  end

  defp empty_token?({:text, text}), do: String.trim(text) == ""
  defp empty_token?({:link, _text, _url}), do: false
end
