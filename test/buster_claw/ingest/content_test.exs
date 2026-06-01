defmodule BusterClaw.Ingest.ContentTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Ingest.Content

  test "parses article HTML into markdown-ish content" do
    item =
      Content.parse_article(
        "https://example.com/story",
        """
        <html>
          <head><title>Example Story</title><script>bad()</script></head>
          <body><article><h1>Ignored</h1><p>Hello &amp; welcome.</p></article></body>
        </html>
        """,
        ["ai"]
      )

    assert item.url == "https://example.com/story"
    assert item.title == "Example Story"
    assert item.tags == ["ai"]
    assert item.content =~ "# Example Story"
    assert item.content =~ "Hello & welcome."
    refute item.content =~ "bad()"
  end

  test "expands RSS items" do
    items =
      Content.parse_rss(
        "https://example.com/feed.xml",
        """
        <rss>
          <channel>
            <item>
              <title>First</title>
              <link>https://example.com/first</link>
              <description><![CDATA[<p>First body</p>]]></description>
            </item>
            <item>
              <title>Second</title>
              <link>https://example.com/second</link>
              <description>Second body</description>
            </item>
          </channel>
        </rss>
        """,
        ["rss"]
      )

    assert Enum.map(items, & &1.url) == [
             "https://example.com/first",
             "https://example.com/second"
           ]

    assert Enum.map(items, & &1.title) == ["First", "Second"]
    assert Enum.all?(items, &(&1.tags == ["rss"]))
  end

  test "expands Atom entries" do
    [item] =
      Content.parse_rss(
        "https://example.com/atom.xml",
        """
        <feed>
          <entry>
            <title>Atom Post</title>
            <link href="https://example.com/atom-post" />
            <summary>Atom body</summary>
          </entry>
        </feed>
        """
      )

    assert item.url == "https://example.com/atom-post"
    assert item.title == "Atom Post"
    assert item.content =~ "Atom body"
  end
end
