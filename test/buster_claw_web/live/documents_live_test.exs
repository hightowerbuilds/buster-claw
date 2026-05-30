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
    assert has_element?(view, "#documents-reader")
    assert has_element?(view, "#documents-sidebar")
    assert has_element?(view, "#documents-sidebar-bumper")
    assert has_element?(view, "#documents-main")
    assert html =~ "Live Doc"
    assert view |> element("#document-preview") |> render() =~ "Preview me."

    view
    |> element("#document-list-item-#{document.id}", "Live Doc")
    |> render_click()

    assert has_element?(view, "#document-preview")
    assert view |> element("#document-preview") |> render() =~ "Preview me."
  end

  test "switches the main reader from the sidebar list", %{conn: conn} do
    assert {:ok, older_document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "older-doc.md",
               name: "Older Doc",
               content: "# Older Doc\n\nOlder body."
             })

    assert {:ok, newer_document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-08],
               filename: "newer-doc.md",
               name: "Newer Doc",
               content: "# Newer Doc\n\nNewer body."
             })

    {:ok, view, html} = live(conn, ~p"/documents")

    assert html =~ "Newer Doc"
    assert view |> element("#document-preview") |> render() =~ "Newer body."
    refute view |> element("#document-preview") |> render() =~ "Older body."

    view
    |> element("#document-list-item-#{older_document.id}", "Older Doc")
    |> render_click()

    assert view |> element("#document-preview") |> render() =~ "Older body."
    refute view |> element("#document-preview") |> render() =~ "Newer body."

    view
    |> element("#document-list-item-#{newer_document.id}", "Newer Doc")
    |> render_click()

    assert view |> element("#document-preview") |> render() =~ "Newer body."
    refute view |> element("#document-preview") |> render() =~ "Older body."
  end

  test "source url opens in the in-app browser instead of leaving the app", %{conn: conn} do
    assert {:ok, _document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "sourced.md",
               name: "Sourced Doc",
               source_url: "https://example.com/article",
               content: "# Sourced Doc\n\nBody."
             })

    {:ok, view, _html} = live(conn, ~p"/documents")

    link_html = view |> element("a", "Open Source") |> render()
    assert link_html =~ "/browse?url=https%3A%2F%2Fexample.com%2Farticle"
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
