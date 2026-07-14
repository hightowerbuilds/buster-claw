defmodule BusterClawWeb.BrowserPagesControllerTest do
  use BusterClawWeb.ConnCase, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "bc-bpages-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "pages"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "lists agent pages with titles, linking through /ws/file", %{conn: conn, root: root} do
    File.write!(
      Path.join([root, "pages", "star-chart.html"]),
      "<html><head><title>Star Chart</title></head></html>"
    )

    body = conn |> get(~p"/browser/pages") |> response(200)

    assert body =~ "Star Chart"
    assert body =~ "star-chart.html"
    assert body =~ "/ws/file?path=" <> URI.encode_www_form("/pages/star-chart.html")
  end

  test "escapes hostile titles", %{conn: conn, root: root} do
    File.write!(
      Path.join([root, "pages", "evil.html"]),
      "<html><head><title>x<\/title></head><body></body></html>"
    )

    # A title regex capture can't cross "<", but the filename itself renders too.
    File.write!(Path.join([root, "pages", "a&b.html"]), "<html></html>")

    body = conn |> get(~p"/browser/pages") |> response(200)
    assert body =~ "a&amp;b.html"
  end

  test "shows the empty state when no agent pages exist", %{conn: conn} do
    body = conn |> get(~p"/browser/pages") |> response(200)
    assert body =~ "Nothing here yet"
  end
end
