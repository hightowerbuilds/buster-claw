defmodule BusterClawWeb.SketchComponentTest do
  # Phase 1's exit tests, driven through the real `/studio` surface rather than
  # the component in isolation — the interesting failures are in the wiring
  # (does the tab switch reload it? does the hook's event reach the component?)
  # and an isolated render cannot see any of them.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Sketch.{Assets, Document, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_sketchui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp open_sketch(conn) do
    {:ok, view, _html} = live(conn, ~p"/studio")
    render_click(view, "select_studio_tab", %{"tab" => "sketch"})
    view
  end

  defp surface(view), do: element(view, "#studio-sketch-surface")

  defp draw(view, points) do
    render_hook(surface(view), "stroke", %{"points" => points})
  end

  defp ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-sketch-element]")
    |> LazyHTML.attribute("data-sketch-element")
  end

  describe "drawing" do
    test "a committed stroke becomes an element on the page", %{conn: conn} do
      view = open_sketch(conn)

      html = draw(view, [[0, 0], [10, 10]])

      assert html =~ "M 0 0 L 10 10"

      assert ids(view) == [],
             "no hit targets in draw mode — they would swallow pointerdown"
    end

    test "the stroke uses the toolbar's current colour and width", %{conn: conn} do
      view = open_sketch(conn)

      render_click(element(view, "[data-sketch-color='#2FD068']"))
      render_click(element(view, "[data-sketch-size='16']"))
      html = draw(view, [[1, 1], [2, 2]])

      assert html =~ ~s(stroke="#2FD068")
      assert html =~ ~s(stroke-width="16")
    end

    test "a stroke the element model refuses is dropped and said out loud", %{conn: conn} do
      view = open_sketch(conn)

      html = draw(view, [[0, 0], ["not", "a point"]])

      assert html =~ "could not be saved"
      assert Store.load("untitled") == {:error, :not_found}
    end
  end

  describe "deleting — the whole point of the phase" do
    test "erasing one mark leaves every other one exactly as it was", %{conn: conn} do
      view = open_sketch(conn)
      for i <- 1..5, do: draw(view, [[i, i], [i + 1, i + 1]])

      render_click(element(view, "[data-sketch-tool='erase']"))
      [_, second | _] = all = ids(view)
      assert length(all) == 5

      render_hook(surface(view), "erase", %{"id" => second})

      remaining = ids(view)
      assert length(remaining) == 4
      refute second in remaining
      assert remaining == List.delete(all, second)
    end

    test "erasing something already gone is not an error", %{conn: conn} do
      # The pointer crosses a stroke twice before the first round trip lands.
      view = open_sketch(conn)
      draw(view, [[0, 0], [5, 5]])
      render_click(element(view, "[data-sketch-tool='erase']"))
      [id] = ids(view)

      render_hook(surface(view), "erase", %{"id" => id})
      html = render_hook(surface(view), "erase", %{"id" => id})

      refute html =~ "could not"
    end
  end

  describe "selecting and moving" do
    test "selecting shows Delete, and deleting removes just that mark", %{conn: conn} do
      view = open_sketch(conn)
      draw(view, [[0, 0], [5, 5]])
      draw(view, [[20, 20], [25, 25]])
      render_click(element(view, "[data-sketch-tool='select']"))
      [first, _second] = ids(view)

      html = render_hook(surface(view), "select", %{"id" => first})
      assert html =~ "delete_selected"

      render_click(element(view, "button[phx-click='delete_selected']"))
      assert length(ids(view)) == 1
      refute first in ids(view)
    end

    test "moving translates the mark and keeps its place in the stack", %{conn: conn} do
      view = open_sketch(conn)
      draw(view, [[0, 0], [10, 0]])
      draw(view, [[0, 50], [10, 50]])
      render_click(element(view, "[data-sketch-tool='select']"))
      [first, _] = before = ids(view)

      html = render_hook(surface(view), "move", %{"id" => first, "dx" => 5, "dy" => 5})

      assert html =~ "M 5 5 L 15 5"
      assert ids(view) == before, "moving must not reorder — it is not the same as raising"
    end

    test "selecting an id that is not here selects nothing", %{conn: conn} do
      view = open_sketch(conn)
      draw(view, [[0, 0], [1, 1]])
      render_click(element(view, "[data-sketch-tool='select']"))

      html = render_hook(surface(view), "select", %{"id" => "el_nope"})

      refute html =~ "delete_selected"
    end
  end

  describe "undo" do
    test "brings back what the last change removed", %{conn: conn} do
      view = open_sketch(conn)
      for i <- 1..3, do: draw(view, [[i, i], [i + 1, i + 1]])
      render_click(element(view, "[data-sketch-tool='erase']"))
      [_, second | _] = before = ids(view)

      render_hook(surface(view), "erase", %{"id" => second})
      assert length(ids(view)) == 2

      render_click(element(view, "button[phx-click='undo']"))
      assert ids(view) == before
    end

    test "undoes a clear", %{conn: conn} do
      view = open_sketch(conn)
      for i <- 1..3, do: draw(view, [[i, i], [i + 1, i + 1]])
      before = ids(view)

      render_click(element(view, "button[phx-click='clear']"))
      assert ids(view) == []

      render_click(element(view, "button[phx-click='undo']"))
      assert ids(view) == before
    end

    test "undo is disabled on a fresh sketch and does nothing if forced", %{conn: conn} do
      view = open_sketch(conn)

      assert render(view) =~ "disabled"
      # Targeted at the component, not the LiveView. `render_click(view, ...)`
      # posts to the parent, which has no clause for it and raises — which would
      # make this test pass for the wrong reason if it were wrapped in a rescue.
      render_hook(surface(view), "undo", %{})
      assert ids(view) == []
    end

    test "an undone change is written to disk, not only to the screen", %{conn: conn} do
      # Undo that only moves the page leaves the file holding the change you just
      # took back — and the next load brings it right back.
      view = open_sketch(conn)
      draw(view, [[0, 0], [5, 5]])
      draw(view, [[9, 9], [12, 12]])

      render_click(element(view, "button[phx-click='undo']"))

      assert {:ok, doc} = Store.load("untitled")
      assert Document.size(doc) == 1
    end
  end

  describe "persistence — the other half of the phase" do
    test "the drawing survives leaving the tab and coming back", %{conn: conn} do
      # The exact loss Phase 0 had to warn about in the footer. `:if={@tab ==
      # "sketch"}` still removes the whole subtree; the difference is that the
      # document is on disk rather than in the DOM.
      view = open_sketch(conn)
      draw(view, [[3, 3], [30, 30]])
      before = ids(view)

      render_click(view, "select_studio_tab", %{"tab" => "mix"})
      render_click(view, "select_studio_tab", %{"tab" => "sketch"})

      assert ids(view) == before
      assert render(view) =~ "M 3 3 L 30 30"
    end

    test "the drawing survives a fresh mount, which is what a reload is", %{conn: conn} do
      view = open_sketch(conn)
      draw(view, [[7, 7], [8, 8]])
      before = ids(view)

      assert ids(open_sketch(conn)) == before
    end

    test "a sketch is a JSON file in the workspace", %{conn: conn} do
      view = open_sketch(conn)
      draw(view, [[0, 0], [1, 1]])

      path = Path.join(Store.dir(), "untitled.json")
      assert File.exists?(path)
      assert {:ok, %{"elements" => [_one]}} = path |> File.read!() |> Jason.decode()
    end

    test "an unreadable sketch opens empty, says so, and does not overwrite it", %{conn: conn} do
      # Handing back a blank canvas that then autosaves is how someone destroys
      # the drawing they were trying to recover.
      File.mkdir_p!(Store.dir())
      path = Path.join(Store.dir(), "untitled.json")
      File.write!(path, "not json at all")

      view = open_sketch(conn)
      html = render(view)

      assert html =~ "could not be read"
      draw(view, [[0, 0], [1, 1]])
      assert File.read!(path) == "not json at all", "the unreadable file was overwritten"
    end
  end

  describe "authorship" do
    test "everything the operator draws is stamped as theirs", %{conn: conn} do
      # D6's boundary is built on this field. A stroke that arrived unattributed —
      # or attributed to the model — would be one the model may later delete.
      view = open_sketch(conn)
      draw(view, [[0, 0], [1, 1]])

      assert {:ok, doc} = Store.load("untitled")
      assert Enum.map(doc.elements, & &1.author) == [:operator]
    end
  end

  describe "images" do
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAFElEQVR4nGP8" <>
             "z8Dwn4GBgYEJRAAAHAAD/1a0lqcAAAAASUVORK5CYII="
         )

    defp drop_file(view, binary, name \\ "shot.png") do
      path = Path.join(System.tmp_dir!(), "bc_drop_#{System.unique_integer([:positive])}_#{name}")
      File.write!(path, binary)
      on_exit(fn -> File.rm(path) end)

      render_hook(element(view, "#studio-sketch"), "drop_paths", %{"paths" => [path]})
    end

    test "a dropped image becomes an element pointing at the sidecar", %{conn: conn} do
      view = open_sketch(conn)

      html = drop_file(view, @png)

      assert html =~ "<image"
      assert html =~ ~r|/sketches/untitled/[0-9a-f]{16}\.png|
      assert {:ok, doc} = Store.load("untitled")
      assert [%{kind: :image, author: :operator}] = doc.elements
    end

    test "it lands centred on where it was dropped", %{conn: conn} do
      # You point at where you want the picture, not at where its top-left
      # should be. The point is pushed before the bytes, because uploading is
      # asynchronous and by then the pointer has moved.
      view = open_sketch(conn)
      render_hook(element(view, "#studio-sketch"), "drop_point", %{"x" => 300, "y" => 200})

      drop_file(view, @png)

      assert {:ok, doc} = Store.load("untitled")
      [image] = doc.elements
      assert image.x == 300.0 - image.w / 2
      assert image.y == 200.0 - image.h / 2
    end

    test "a large image is scaled down but keeps its shape", %{conn: conn} do
      # A phone screenshot is 1179px wide and the panel is not. A distorted
      # image is worse than a small one.
      view = open_sketch(conn)
      wide = <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 8, 500::16, 1000::16, 3, 0xFF, 0xD9>>

      drop_file(view, wide, "wide.jpg")

      assert {:ok, doc} = Store.load("untitled")
      [image] = doc.elements
      assert image.w <= 420 and image.h <= 420
      assert_in_delta image.w / image.h, 1000 / 500, 0.01
    end

    test "the same image dropped twice is stored once", %{conn: conn} do
      view = open_sketch(conn)

      drop_file(view, @png)
      drop_file(view, @png)

      assert {:ok, doc} = Store.load("untitled")
      assert length(doc.elements) == 2
      assert length(Assets.list("untitled")) == 1, "content-naming should have deduped the file"
    end

    test "a file that is not an image is refused and nothing is written", %{conn: conn} do
      view = open_sketch(conn)

      html = drop_file(view, "#!/bin/sh\nrm -rf /", "evil.png")

      assert html =~ "not a PNG"
      assert Assets.list("untitled") == []
      assert Store.load("untitled") == {:error, :not_found}
    end

    test "a client-side refusal is reported in the server's own words", %{conn: conn} do
      view = open_sketch(conn)

      html =
        render_hook(element(view, "#studio-sketch"), "drop_refused", %{
          "reason" => "too_large",
          "filename" => "huge.png"
        })

      assert html =~ "huge.png"
      assert html =~ "MB"
    end

    test "an unrecognised refusal reason does not mint an atom", %{conn: conn} do
      # The hook sends the server's own vocabulary back. A crafted payload must
      # not reach the atom table.
      view = open_sketch(conn)

      html =
        render_hook(element(view, "#studio-sketch"), "drop_refused", %{
          "reason" => "wat_#{System.unique_integer([:positive])}",
          "filename" => "x.png"
        })

      assert html =~ "could not be read"
    end

    test "an image can be selected and deleted like anything else", %{conn: conn} do
      view = open_sketch(conn)
      drop_file(view, @png)
      render_click(element(view, "[data-sketch-tool='select']"))
      [id] = ids(view)

      render_hook(surface(view), "select", %{"id" => id})
      render_click(element(view, "button[phx-click='delete_selected']"))

      assert ids(view) == []
      assert {:ok, doc} = Store.load("untitled")
      assert doc.elements == []
    end

    test "an image survives a reload", %{conn: conn} do
      view = open_sketch(conn)
      drop_file(view, @png)
      before = ids(view)

      assert ids(open_sketch(conn)) == before
      assert render(open_sketch(conn)) =~ "<image"
    end

    test "the route serves the bytes back", %{conn: conn} do
      view = open_sketch(conn)
      drop_file(view, @png)
      [source] = Assets.list("untitled")

      response = get(conn, ~p"/sketches/untitled/#{source}")

      assert response.status == 200
      assert response.resp_body == @png
      assert get_resp_header(response, "content-type") == ["image/png"]
      assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    end

    test "the route refuses a name Assets did not mint", %{conn: conn} do
      for bad <- ["..%2F..%2Fplan.json", "0123456789abcdef.svg", "nope.png"] do
        assert get(conn, "/sketches/untitled/#{bad}").status == 404
      end
    end
  end
end
