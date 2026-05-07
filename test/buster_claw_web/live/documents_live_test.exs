defmodule BusterClawWeb.DocumentsLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Library

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-documents-live-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "renders indexed documents and previews a markdown body", %{conn: conn} do
    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "live-doc.md",
               name: "Live Doc",
               content: "# Live Doc\n\nPreview me."
             })

    {:ok, view, html} = live(conn, ~p"/documents")

    assert html =~ "Documents"
    assert html =~ "Live Doc"

    html =
      view
      |> element("button[phx-value-id='#{document.id}']", "Live Doc")
      |> render_click()

    assert html =~ "Preview me."
  end

  test "indexes existing documents from the UI", %{conn: conn} do
    root = Application.fetch_env!(:buster_claw, :library_root)
    path = Path.join([root, "raw", "2026-05-07", "legacy.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nname: \"Legacy\"\n---\n\nLegacy body.")

    {:ok, view, html} = live(conn, ~p"/documents")
    assert html =~ "No documents indexed yet"

    html = render_click(view, "index_existing")

    assert html =~ "Legacy"
    assert html =~ "1 documents"
  end
end
