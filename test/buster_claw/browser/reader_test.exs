defmodule BusterClaw.Browser.ReaderTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Browser.Reader

  test "extracts text and resolves links to absolute http(s) URLs" do
    html = ~s|<p>Hello <a href="/about">about us</a> world</p>|
    tokens = Reader.to_tokens(html, "https://example.com/home")

    assert {:link, "about us", "https://example.com/about"} in tokens
    assert Enum.any?(tokens, fn {kind, text} -> kind == :text and text =~ "Hello" end)
  end

  test "keeps absolute links as-is" do
    html = ~s|<a href="https://other.test/x">elsewhere</a>|

    assert [{:link, "elsewhere", "https://other.test/x"}] =
             Reader.to_tokens(html, "https://example.com")
  end

  test "renders non-fetchable links (mailto/#/javascript) as plain text" do
    html =
      ~s|<a href="mailto:a@b.com">mail</a> <a href="#top">top</a> <a href="javascript:x()">x</a>|

    tokens = Reader.to_tokens(html, "https://example.com")

    refute Enum.any?(tokens, fn t -> elem(t, 0) == :link end)
    assert Enum.any?(tokens, fn {:text, t} -> t =~ "mail" end)
  end

  test "strips scripts and styles, never emitting their contents as links" do
    html = ~s|<script>var x = "<a href='/evil'>x</a>"</script><p>Safe</p>|
    tokens = Reader.to_tokens(html, "https://example.com")

    refute Enum.any?(tokens, fn t -> elem(t, 0) == :link end)
    assert Enum.any?(tokens, fn {:text, t} -> t =~ "Safe" end)
  end

  test "uses the URL as link text when the anchor body is empty" do
    html = ~s|<a href="https://example.com/page"></a>|

    assert [{:link, "https://example.com/page", "https://example.com/page"}] =
             Reader.to_tokens(html, "https://example.com")
  end
end
