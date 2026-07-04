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
  end
end
