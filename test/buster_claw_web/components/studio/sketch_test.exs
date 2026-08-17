defmodule BusterClawWeb.Studio.SketchTest do
  # The Sketch Pad's toolbar markup. Behaviour is `SketchComponentTest`, which
  # drives the real surface; geometry is `assets/js/lib/sketch.test.js`.
  #
  # Structure, not behaviour, deliberately: there is no DOM harness in this repo
  # (LEFTOVERS_PLATFORM records that), so a test that clicked a swatch and looked
  # at pixels would be a test of nothing.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BusterClaw.Sketch.Element
  alias BusterClawWeb.Studio.Sketch

  defp toolbar(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          target: "#sketch",
          tool: :draw,
          color: Sketch.default_color(),
          width: Sketch.default_width(),
          text_size: Sketch.default_text_size(),
          selected: nil,
          undoable: false
        },
        overrides
      )

    render_component(&Sketch.toolbar/1, assigns)
  end

  defp classes(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute("class")
  end

  describe "the controls" do
    test "five colours and three sizes, each carrying its own value" do
      html = toolbar()

      for color <- Sketch.colors() do
        assert html =~ ~s(data-sketch-color="#{color}"), "the palette lost #{color}"
      end

      for width <- Sketch.widths() do
        assert html =~ ~s(data-sketch-size="#{width}")
      end
    end

    test "all three tools are reachable" do
      html = toolbar()

      assert html =~ ~s(data-sketch-tool="text")
      assert html =~ ~s(data-sketch-tool="erase")
      assert html =~ ~s(data-sketch-tool="select")
    end

    test "every control posts to the component that owns the document" do
      # A toolbar button with no `phx-target` posts to the parent LiveView, where
      # nothing handles it — the click is silently swallowed and the tool never
      # changes. Nothing else in the suite would notice.
      #
      # Written as buttons-vs-targeted-buttons rather than against a count of
      # the groups. The count version was a number that had to be edited every
      # time a control was added, which makes it a chore rather than a guard —
      # and it says nothing about the button that was actually added.
      for tool <- [:draw, :text, :erase, :select] do
        doc = toolbar(%{tool: tool}) |> LazyHTML.from_fragment()

        buttons = doc |> LazyHTML.query("button") |> Enum.count()
        targeted = doc |> LazyHTML.query("button[phx-target]") |> Enum.count()

        assert buttons > 0
        assert targeted == buttons, "a button in #{tool} mode is missing its phx-target"
      end
    end
  end

  describe "the text tool's controls" do
    test "the label field and its sizes appear only with the text tool up" do
      refute toolbar() =~ "data-sketch-text"

      html = toolbar(%{tool: :text})
      assert html =~ "data-sketch-text"

      for size <- Element.text_sizes() do
        assert html =~ ~s(data-sketch-text-size="#{size}")
      end
    end

    test "the brush sizes step aside for the label sizes" do
      # Two groups both labelled "Size" means reading both to find out which one
      # you are about to change.
      html = toolbar(%{tool: :text})

      refute html =~ "data-sketch-size=", "the brush widths are still showing in text mode"
    end

    test "the field holds no server-side value, because the browser owns it" do
      # `phx-update=\"ignore\"` and no `value` attribute: what is typed belongs
      # to the browser until the click that places it. A `value` here would let
      # LiveView blank the field on any unrelated re-render.
      html = toolbar(%{tool: :text})

      assert html =~ ~s(phx-update="ignore")

      value =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-sketch-text]")
        |> LazyHTML.attribute("value")

      assert value == []
    end

    test "the default label size is one the toolbar can actually press" do
      # A default outside the offered set leaves every size button unlit and no
      # way to get back to it.
      assert Sketch.default_text_size() in Element.text_sizes()
      assert toolbar(%{tool: :text}) =~ ~s(data-sketch-text-size="#{Sketch.default_text_size()}")
    end

    test "the held colour stays pressed while the text tool is up" do
      # Text draws in a colour too, so the colour group is not released the way
      # it is for the eraser — and picking one must not put the text tool down.
      assert toolbar(%{tool: :text, color: "#1C9BFF"}) =~
               ~s(data-sketch-color="#1C9BFF" data-active)
    end
  end

  describe "pressed state follows the assigns" do
    test "the held colour and width are pressed, and nothing else is" do
      html = toolbar(%{color: "#1C9BFF", width: 16})

      assert html =~ ~s(data-sketch-color="#1C9BFF" data-active)
      assert html =~ ~s(data-sketch-size="16" data-active)
      assert Regex.scan(~r/data-active/, html) |> length() == 2
    end

    test "a tool other than draw releases every colour" do
      # The defect Phase 0 fixed, now enforced by the assigns rather than by JS:
      # you cannot be erasing while a colour still reads as selected.
      html = toolbar(%{tool: :erase})

      refute html =~ "data-sketch-color=\"#F4F1EA\" data-active"
      assert html =~ ~s(data-sketch-tool="erase" data-active)
    end
  end

  describe "the active look lives in the markup" do
    test "size buttons carry both halves of their pressed style" do
      assert toolbar() =~ "data-[active]:border-primary data-[active]:text-primary"
    end

    # Scoped to the toggles. Written first as "no button anywhere hardcodes
    # border-primary", it failed against Clear, which carries `border-primary/50`
    # unconditionally and is right to — Clear is not a toggle and has no pressed
    # state. A universal over the whole document asserted something the surface
    # never promised.
    test "a toggle button's pressed styling is never unconditional" do
      html = toolbar()

      for selector <- ~w([data-sketch-color] [data-sketch-size] [data-sketch-tool]),
          class <- classes(html, selector) do
        refute class =~ ~r/(?<!data-\[active\]:)\btext-primary\b/,
               "#{selector} applies text-primary unconditionally: #{class}"

        refute class =~ ~r/(?<!data-\[active\]:)\bborder-primary\b/,
               "#{selector} applies border-primary unconditionally: #{class}"
      end
    end

    test "buttons in the same group render identical class lists" do
      # The shape the original bug had: `if(i == 0, do: ...)` inside a `:for`, so
      # one rendered button differed from its siblings.
      html = toolbar()

      for selector <- ~w([data-sketch-color] [data-sketch-size]) do
        assert html |> classes(selector) |> Enum.uniq() |> length() == 1,
               "#{selector} buttons differ in styling — pressed state is back in the classes"
      end
    end
  end

  describe "destructive controls" do
    test "Delete appears only when something is selected" do
      refute toolbar() =~ "delete_selected"
      assert toolbar(%{selected: "el_x"}) =~ "delete_selected"
    end

    test "Undo is disabled until there is something to undo" do
      assert toolbar() =~ "disabled"
      refute toolbar(%{undoable: true}) =~ ~s(phx-click="undo" phx-target="#sketch" disabled)
    end

    test "Clear still asks, because undo is one step and Clear is all of them" do
      assert toolbar() =~ "data-claw-confirm"
    end
  end

  describe "the status line" do
    test "names the file and counts the marks" do
      html = render_component(&Sketch.status/1, %{notice: nil, count: 3, name: "untitled"})

      assert html =~ "untitled.json"
      assert html =~ "3 marks"
      assert html =~ "saved as you draw"
    end

    test "counts one mark in the singular" do
      assert render_component(&Sketch.status/1, %{notice: nil, count: 1, name: "x"}) =~ "1 mark"
    end

    # Phase 0 asserted the opposite of this: that the footer WARNED a tab switch
    # would clear the drawing. That was the honest thing to say while it was
    # true. Phase 1 made it false, so the guard is inverted rather than deleted —
    # a surface that still warned about losing work would now be scaring people
    # about something that does not happen.
    test "no longer warns about losing the drawing, because it no longer does" do
      html = render_component(&Sketch.status/1, %{notice: nil, count: 2, name: "x"})

      refute html =~ "leaving this tab"
      refute html =~ "reload"
      refute html =~ "nothing is saved"
    end

    test "names the model's share only when the model has drawn something" do
      # D7's legend. A marker nobody can name is a smudge — and on a sketch the
      # model has never touched, saying "0 by the model" would be talking about
      # a collaborator who is not there.
      solo =
        render_component(&Sketch.status/1, %{notice: nil, count: 4, model_count: 0, name: "x"})

      refute solo =~ "by the model"

      shared =
        render_component(&Sketch.status/1, %{notice: nil, count: 4, model_count: 2, name: "x"})

      assert shared =~ "2 by the model"
      assert shared =~ "bg-primary", "the legend has to show the marker it names"
    end

    test "a notice is shown when there is one" do
      html = render_component(&Sketch.status/1, %{notice: "Could not write", count: 0, name: "x"})

      assert html =~ "Could not write"
    end
  end
end
