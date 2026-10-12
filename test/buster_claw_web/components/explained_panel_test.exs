defmodule BusterClawWeb.ExplainedPanelTest do
  @moduledoc """
  The lockstep the Explained rail did not have.

  `status_live_test.exs` sweeps the tutorials for their demo contract and
  refuses a forged sub-tab key, but nothing asserted that a key in
  `Explained.Registry` has a **dispatch line** — so a `@features` entry added
  with no panel rendered a rail button, a launcher tile, and an empty page, and
  every existing test stayed green. `Studio.Registry` has had this guard since
  the day it was built and it has caught two real bugs; this is the same guard
  for the same shape.

  Kept as its own file rather than added to `status_live_test.exs` because it
  needs no LiveView: `explained_panel/1` is a function component, so a render is
  the whole fixture.
  """
  use BusterClawWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias BusterClawWeb.Explained.Registry
  alias BusterClawWeb.ExplainedPanel

  # Every panel module renders exactly one `<h2>` — the tab's own title. It is
  # the cheapest thing that distinguishes "a body rendered" from "the rail
  # rendered and nothing else", and it needs no markup added to the dispatch.
  defp headings(html), do: html |> then(&Regex.scan(~r/<h2/, &1)) |> length()

  defp render_tab(tab), do: render_component(&ExplainedPanel.explained_panel/1, tab: tab)

  describe "the registry is the single source of truth" do
    test "tab_keys/0 is the registry, in rail order" do
      assert ExplainedPanel.tab_keys() == Enum.map(Registry.tabs(), &elem(&1, 0))

      # A review-forcing snapshot, and deliberately: the rail order is an
      # operator decision (Intro leads, the two outbound site tabs sit last),
      # and it is not visible in any other assertion. Adding a tab should make
      # this line fail and be updated on purpose.
      # `ramshackle` merged into `studio` on 08-16 and its module was deleted.
      assert ExplainedPanel.tab_keys() ==
               ~w(intro models gws browser phone shaders pockets cmd studio site ntf)
    end

    test "every registry tab renders a body, and every dispatch has a registry tab" do
      # Forward: a tab in the registry with no dispatch line renders the rail
      # and an empty pane. That is exactly what a new `@features` entry looks
      # like before its module exists, and it is what this catches.
      for tab <- ExplainedPanel.tab_keys() do
        assert headings(render_tab(tab)) == 1,
               "sub-tab #{tab} is in the registry but nothing dispatches a body for it"
      end

      # Backward: a dispatch for a key the registry does not have is
      # unreachable, so no render can see it. Asserted against the source, the
      # same way SettingsTabsTest and StudioPanelTest see an orphan.
      panel = Path.expand("../../../lib/buster_claw_web/components/explained_panel.ex", __DIR__)

      literals =
        ~r/@tab == "([a-z_]+)"/
        |> Regex.scan(File.read!(panel))
        |> Enum.map(fn [_, key] -> key end)

      stub_keys = Enum.map(Registry.stubs(), & &1.key)

      assert Enum.sort(literals ++ stub_keys) == Enum.sort(ExplainedPanel.tab_keys())
    end

    test "an unknown tab renders the rail and no body" do
      # The negative half of the forward assertion above: it only means
      # something if a key with no dispatch really does render zero headings.
      html = render_tab("not-a-tab")

      assert headings(html) == 0
      assert html =~ ~s(phx-value-tab="intro")
    end
  end

  describe "the Pockets tutorial" do
    test "it teaches that roles describe a Pocket and never decide one" do
      html = render_tab("pockets")

      # The sentence the tab exists to deliver. Both halves: the fixed name,
      # and the failure it prevents.
      assert html =~ "Roles describe a Pocket. They never decide one."
      assert html =~ "backgrounds"
      assert html =~ "silently relocate"

      # And the rule it rests on, from `BusterClaw.Pocket`'s own moduledoc.
      assert html =~ "The manifest holds description. It never holds permission."
    end

    test "it names the three surfaces that already use a Pocket" do
      html = render_tab("pockets")

      for pocket <- ~w(pockets/backgrounds/ pockets/nav-home/ pockets/contact-faces/) do
        assert html =~ pocket, "the tab claims Pockets are load-bearing but never names #{pocket}"
      end
    end

    test "the read fence is taught as re-asked, not cached" do
      html = render_tab("pockets")

      assert html =~ "re-asked on every single call, and nothing is cached"
      assert html =~ "bare name"
      # The consequence that makes the guard worth stating.
      assert html =~ "Unmounting deletes nothing."
    end

    test "mounting is taught as an operator act with no command behind it" do
      html = render_tab("pockets")

      assert html =~ "There is no verb for this, and the absence is the design."

      # The one prompt on this page that is NOT chat input must not offer to
      # prefill the composer — the same call the GWS unattended cycle made.
      # Offering "Try in Chat" for a thing no verb can do teaches the opposite
      # of what the paragraph says.
      [_, block] = String.split(html, "Mount my ~/Pictures folder", parts: 2)
      [block, _] = String.split(block, "</figure>", parts: 2)
      refute block =~ "explained_try_in_chat"
    end

    test "its closing button names a Home tab the parent will actually accept" do
      # The one cross-module coupling on this page. The Pockets tab is a home
      # SUB-tab with no URL, so the tutorial ends with the parent's own
      # `select_home_tab` event rather than a `navigate` — and that event is
      # whitelisted against `home_tabs/0`. Renaming the key there would leave a
      # button that silently does nothing, which no render can see.
      html = render_tab("pockets")

      assert html =~ ~s(phx-click="select_home_tab")
      assert html =~ ~s(phx-value-tab="pockets")

      assert "pockets" in Enum.map(BusterClawWeb.StatusLive.home_tabs(), &elem(&1, 0)),
             "the Pockets tutorial's closing button fires an event StatusLive would refuse"
    end

    test "the tutorial offers nothing that submits" do
      html = render_tab("pockets")

      assert html =~ "Copy prompt"
      refute html =~ ~s(phx-click="send")
    end
  end
end
