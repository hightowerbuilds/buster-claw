defmodule BusterClaw.Ingest.Content do
  @moduledoc "Converts fetched HTML/XML bodies into markdown-ready ingestion items."

  @type item :: %{
          url: String.t(),
          title: String.t() | nil,
          content: String.t(),
          tags: [String.t()]
        }

  def parse_article(url, body, tags \\ []) do
    title = html_title(body) || URI.parse(url).host || url

    %{
      url: url,
      title: title,
      content: html_to_markdown(body, title),
      tags: tags
    }
  end

  def parse_rss(feed_url, body, tags \\ []) do
    body
    |> scan_entries()
    |> Enum.map(fn entry ->
      url = entry.link || feed_url
      title = entry.title || URI.parse(url).host || url
      content = entry.description || entry.title || url

      %{
        url: url,
        title: title,
        content: html_to_markdown(content, title),
        tags: tags
      }
    end)
  end

  def html_to_markdown(html, title \\ nil) do
    text =
      html
      |> strip_unwanted_blocks()
      |> replace_block_tags()
      |> strip_tags()
      |> html_entities()
      |> normalize_space()

    heading = title && String.trim(title)

    cond do
      heading in [nil, ""] -> text
      String.starts_with?(text, "# ") -> text
      true -> "# #{heading}\n\n#{text}"
    end
  end

  def html_title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, title] -> title |> strip_tags() |> html_entities() |> String.trim()
      _ -> nil
    end
  end

  defp scan_entries(body) do
    cond do
      String.contains?(body, "<item") -> scan_rss_items(body)
      String.contains?(body, "<entry") -> scan_atom_entries(body)
      true -> []
    end
  end

  defp scan_rss_items(body) do
    ~r/<item\b[^>]*>(.*?)<\/item>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [item] ->
      %{
        title: xml_text(item, "title"),
        link: xml_text(item, "link"),
        description: xml_text(item, "description") || xml_text(item, "content:encoded")
      }
    end)
  end

  defp scan_atom_entries(body) do
    ~r/<entry\b[^>]*>(.*?)<\/entry>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [entry] ->
      %{
        title: xml_text(entry, "title"),
        link: atom_link(entry),
        description: xml_text(entry, "summary") || xml_text(entry, "content")
      }
    end)
  end

  defp xml_text(xml, tag) do
    pattern = Regex.compile!("<#{Regex.escape(tag)}\\b[^>]*>(.*?)</#{Regex.escape(tag)}>", "is")

    case Regex.run(pattern, xml) do
      [_, value] -> value |> strip_cdata() |> strip_tags() |> html_entities() |> String.trim()
      _ -> nil
    end
  end

  defp atom_link(entry) do
    case Regex.run(~r/<link\b[^>]*href=["']([^"']+)["'][^>]*>/is, entry) do
      [_, href] -> href
      _ -> xml_text(entry, "link")
    end
  end

  defp strip_cdata(value) do
    value
    |> String.trim()
    |> String.replace_prefix("<![CDATA[", "")
    |> String.replace_suffix("]]>", "")
  end

  defp strip_unwanted_blocks(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<noscript\b[^>]*>.*?<\/noscript>/is, "")
  end

  defp replace_block_tags(html) do
    html
    |> String.replace(~r/<\s*br\s*\/?\s*>/i, "\n")
    |> String.replace(~r/<\/\s*(p|div|section|article|header|footer|li|h[1-6])\s*>/i, "\n\n")
  end

  defp strip_tags(html), do: String.replace(html, ~r/<[^>]+>/, " ")

  defp html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp normalize_space(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end
end
