defmodule BusterClaw.SvgViewerTest do
  use ExUnit.Case, async: true

  alias BusterClaw.SvgViewer

  describe "extract/1" do
    test "pulls an svg block and strips it from the text" do
      text =
        "Here is a moon:\n```svg\n<svg viewBox=\"0 0 10 10\"><circle r=\"5\"/></svg>\n```\nHope it helps."

      {clean, [svg]} = SvgViewer.extract(text)

      assert clean == "Here is a moon:\n\nHope it helps."
      assert svg =~ ~r/^<svg/
      assert svg =~ "circle"
    end

    test "keeps multiple blocks in order and leaves prose clean" do
      text = "a ```svg\n<svg>1</svg>``` b ```svg\n<svg>2</svg>``` c"
      {clean, svgs} = SvgViewer.extract(text)

      assert length(svgs) == 2
      assert Enum.at(svgs, 0) =~ "1"
      assert Enum.at(svgs, 1) =~ "2"
      assert clean == "a  b  c"
    end

    test "drops a block whose body is not an <svg>" do
      {clean, svgs} = SvgViewer.extract("```svg\njust talking about svg\n```")
      assert svgs == []
      assert clean == ""
    end

    test "no svg block yields the text unchanged and an empty list" do
      assert SvgViewer.extract("plain reply") == {"plain reply", []}
    end
  end

  describe "sanitize/1" do
    test "strips <script>, <foreignObject>, on* handlers, and external hrefs" do
      dirty =
        ~s|<svg onload="steal()"><script>evil()</script><foreignObject><b>x</b></foreignObject><image href="https://evil/x.png"/><use xlink:href="//evil/y"/><a href="#ok"/></svg>|

      clean = SvgViewer.sanitize(dirty)

      refute clean =~ "<script"
      refute clean =~ "foreignObject"
      refute clean =~ "onload"
      refute clean =~ "https://evil"
      refute clean =~ "//evil"
      # internal references survive
      assert clean =~ ~s(href="#ok")
    end

    test "leaves a clean svg untouched" do
      ok = ~s(<svg viewBox="0 0 4 4"><path d="M0 0L4 4" stroke="white"/></svg>)
      assert SvgViewer.sanitize(ok) == ok
    end

    test "closes the known regex bypasses" do
      # solidus-separated handler, unclosed <script>, javascript:/data: hrefs
      dirty =
        ~s|<svg><rect/onload="x()"/><script>evil()<a href="javascript:alert(1)"/>| <>
          ~s|<use href="data:image/svg+xml,<svg onload=x>"/><circle href=vbscript:x /></svg>|

      clean = SvgViewer.sanitize(dirty)

      refute clean =~ ~r/onload/i
      refute clean =~ ~r/<script/i
      refute clean =~ "javascript:"
      refute clean =~ "data:image"
      refute clean =~ "vbscript:"
    end

    test "keeps quoted and unquoted internal fragment refs" do
      assert SvgViewer.sanitize(~s(<use href="#grad"/>)) =~ ~s(href="#grad")
      assert SvgViewer.sanitize(~s(<use href='#grad'/>)) =~ ~s(href='#grad')
      assert SvgViewer.sanitize(~s(<use href=#grad/>)) =~ "href=#grad"
    end
  end

  describe "normalize/1" do
    test "injects a viewBox from numeric width/height (the crop fix)" do
      assert SvgViewer.normalize(~s(<svg width="800" height="600"><rect/></svg>)) =~
               ~s(viewBox="0 0 800 600")
    end

    test "handles px units, single quotes, unquoted values, and decimals" do
      assert SvgViewer.normalize(~s(<svg width="800px" height="600px"/>)) =~
               ~s(viewBox="0 0 800 600")

      assert SvgViewer.normalize(~s(<svg width='320' height='240'/>)) =~
               ~s(viewBox="0 0 320 240")

      assert SvgViewer.normalize(~s(<svg width=640 height=480></svg>)) =~
               ~s(viewBox="0 0 640 480")

      assert SvgViewer.normalize(~s(<svg width="12.5" height="7.5"/>)) =~
               ~s(viewBox="0 0 12.5 7.5")
    end

    test "an existing viewBox is left alone" do
      svg = ~s(<svg viewBox="0 0 100 50" width="800" height="600"><rect/></svg>)
      assert SvgViewer.normalize(svg) == svg
    end

    test "non-numeric or missing dimensions pass through untouched" do
      for svg <- [
            ~s(<svg width="100%" height="100%"/>),
            ~s(<svg width="10em" height="4em"/>),
            ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>),
            ~s(<svg width="800"/>),
            ~s(<svg width="0" height="600"/>)
          ] do
        assert SvgViewer.normalize(svg) == svg
      end
    end

    test "stroke-width does not masquerade as width" do
      svg = ~s(<svg stroke-width="2" height="600"><rect/></svg>)
      assert SvgViewer.normalize(svg) == svg
    end

    test "only the root tag is touched, not nested <svg> elements" do
      svg = ~s(<svg viewBox="0 0 10 10"><svg width="5" height="5"/></svg>)
      assert SvgViewer.normalize(svg) == svg
    end
  end
end
