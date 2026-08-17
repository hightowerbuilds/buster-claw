defmodule BusterClawWeb.Studio.SketchTest do
  # The Sketch Pad's toolbar markup. Behaviour is `SketchComponentTest`, which
  # drives the real surface; geometry is `assets/js/lib/sketch.test.js`.
  #
  # Structure, not behaviour, deliberately: there is no DOM harness in this repo
  # (LEFTOVERS_PLATFORM records that), so a test that clicked a swatch and looked
  # at pixels would be a test of nothing.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BusterClawWeb.Studio.Sketch

  defp toolbar(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          target: "#sketch",
          tool: :draw,
          color: Sketch.default_color(),
          width: Sketch.default_width(),
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

    test "both tools are reachable" do
      html = toolbar()

      assert html =~ ~s(data-sketch-tool="erase")
      assert html =~ ~s(data-sketch-tool="select")
    end

    test "every control posts to the component that owns the document" do
      # A toolbar button with no `phx-target` posts to the parent LiveView, where
      # nothing handles it — the click is silently swallowed and the tool never
      # changes. Nothing else in the suite would notice.
      html = toolbar()

      targets =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")
        |> LazyHTML.attribute("phx-target")

      assert length(targets) == length(Sketch.colors()) + length(Sketch.widths()) + 4,
             "a button is missing its phx-target"
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

    test "a notice is shown when there is one" do
      html = render_component(&Sketch.status/1, %{notice: "Could not write", count: 0, name: "x"})

      assert html =~ "Could not write"
    end
  end
end
