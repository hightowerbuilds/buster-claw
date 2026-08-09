defmodule BusterClawWeb.ChatSkinCssTest do
  # A skin is CSS, so the only place its rules can be wrong is a stylesheet — and
  # a stylesheet is the one artifact in this app nothing else asserts against.
  # These are the invariants the skins are allowed to be judged on without a
  # human looking at them; the looking itself is the acceptance walk.
  use ExUnit.Case, async: true

  alias BusterClaw.ChatSkin

  @css Path.join([__DIR__, "..", "..", "assets", "css", "app.css"]) |> Path.expand()

  # Everything from the CHAT SKINS banner to the end of the file. Slicing rather
  # than reading the whole stylesheet keeps these assertions from being about
  # someone else's rules — a hex literal elsewhere in the app is fine.
  defp skin_section do
    css = File.read!(@css)
    [_, section] = String.split(css, "CHAT SKINS —", parts: 2)
    section
  end

  test "the stylesheet is where the skins actually live" do
    assert File.exists?(@css)
    assert skin_section() =~ "data-chat-skin"
  end

  test "every skin but the default has rules of its own" do
    section = skin_section()

    for key <- ChatSkin.keys() -- [ChatSkin.default()] do
      assert section =~ ~s([data-chat-skin="#{key}"]),
             "#{key} is offered in the dropdown and styles nothing — it would " <>
               "silently render as the default look."
    end
  end

  test "the default skin styles nothing at all" do
    # The baseline is the Tailwind utilities in the markup. An empty block is the
    # proof the default look cannot regress through this file, because there is
    # nothing in it to be wrong.
    refute skin_section() =~ ~s([data-chat-skin="#{ChatSkin.default()}"]),
           "the default skin grew rules. If it needs them, the markup and this " <>
             "file now disagree about what the baseline is."
  end

  test "no skin uses a hex colour" do
    # Each skin has to be legible against both daisyUI themes — six combinations
    # — and a literal can only ever be right in one of them. Tokens only.
    hexes =
      Regex.scan(~r/#[0-9a-fA-F]{3,8}\b/, skin_section())
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    assert hexes == [],
           "skin CSS must use var(--color-*) so it survives the light theme. Found: " <>
             Enum.join(hexes, ", ")
  end

  test "no skin hides a control" do
    # A skin may restyle Stop, Steer now and attach however it likes. One that
    # makes them invisible is a bug — the panel would look clean and be unusable,
    # and nothing else in the suite would notice.
    section = skin_section()

    refute section =~ "display: none",
           "a skin hides something. Restyling a control is fine; removing it is not."

    refute section =~ "visibility: hidden"
  end

  test "the skins reach only anchors the markup actually renders" do
    # Every `data-chat-*` selector in the stylesheet has to exist in ChatPanel, or
    # it is a rule that quietly does nothing. This is the pair of the anchor test
    # in ChatPanelTest, from the other side.
    panel = File.read!(Path.expand("../../lib/buster_claw_web/components/chat_panel.ex", __DIR__))

    used =
      Regex.scan(~r/\[data-chat-[a-z-]+/, skin_section())
      |> Enum.map(fn [match] -> String.trim_leading(match, "[") end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "data-chat-skin"))

    # Sanity: the extraction found something, so a silent regex change cannot
    # turn this test into a tautology.
    assert length(used) >= 5

    for anchor <- used do
      assert panel =~ anchor,
             "#{anchor} is styled but never rendered — the rule is dead."
    end
  end
end
