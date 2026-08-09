defmodule BusterClawWeb.BrandUploadTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Library
  alias BusterClaw.Pockets.Brand

  setup do
    root = Path.join(System.tmp_dir!(), "bc_bupload_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    :ok
  end

  defp open_pockets(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "select_home_tab", %{"tab" => "pockets"})
    view
  end

  test "uploading art through the tab actually lands it in the Pocket", %{conn: conn} do
    view = open_pockets(conn)

    assert Brand.status("nav_home") == :default

    # The picker is closed until the slot is chosen.
    refute has_element?(view, "#brand-upload-nav_home")

    view
    |> element(~s(#brand-slot-nav_home button[phx-click="pick_brand"]))
    |> render_click()

    assert has_element?(view, "#brand-upload-nav_home")

    art =
      file_input(view, "#brand-upload-nav_home", :brand, [
        %{name: "claw.png", content: "png-bytes", type: "image/png"}
      ])

    # auto_upload: choosing the file IS the upload. No submit anywhere below.
    render_upload(art, "claw.png")

    assert Brand.status("nav_home") == :custom
    assert Brand.image_url("nav_home") =~ "/pockets/nav-home/"
  end

  test "the dock renders the operator's icon once it is uploaded", %{conn: conn} do
    view = open_pockets(conn)

    view
    |> element(~s(#brand-slot-nav_home button[phx-click="pick_brand"]))
    |> render_click()

    art =
      file_input(view, "#brand-upload-nav_home", :brand, [
        %{name: "claw.png", content: "png-bytes", type: "image/png"}
      ])

    render_upload(art, "claw.png")

    # A fresh mount, because the dock is rendered by the layout.
    {:ok, _fresh, html} = live(conn, ~p"/")
    assert html =~ "/pockets/nav-home/"
  end

  test "the OPEN page updates its dock and banner without a reload", %{conn: conn} do
    view = open_pockets(conn)

    refute render(view) =~ "/pockets/nav-home/"

    view
    |> element(~s(#brand-slot-nav_home button[phx-click="pick_brand"]))
    |> render_click()

    art =
      file_input(view, "#brand-upload-nav_home", :brand, [
        %{name: "claw.png", content: "png-bytes", type: "image/png"}
      ])

    render_upload(art, "claw.png")

    # The dock lives in the layout and the banner in StatusLive's own render —
    # both outside the component that handled the upload.
    html = render(view)
    assert html =~ "/pockets/nav-home/", "the dock did not pick up the new icon"
  end

  test "another open surface updates too, without being touched", %{conn: conn} do
    # The dock is in the layout, so the surface that changes is usually NOT the
    # one the operator uploaded on — and often not the same LiveView process.
    {:ok, other, _html} = live(conn, ~p"/terminal")
    refute render(other) =~ "/pockets/nav-home/"

    view = open_pockets(conn)

    view
    |> element(~s(#brand-slot-nav_home button[phx-click="pick_brand"]))
    |> render_click()

    art =
      file_input(view, "#brand-upload-nav_home", :brand, [
        %{name: "claw.png", content: "png-bytes", type: "image/png"}
      ])

    render_upload(art, "claw.png")

    # The broadcast reached the other view and its assigns changed, which is
    # what makes the swap visible to LiveView's diff rather than only to a
    # full re-render.
    assert render(other) =~ "/pockets/nav-home/"
  end

  test "clearing returns the slot to the shipped default", %{conn: conn} do
    view = open_pockets(conn)

    view
    |> element(~s(#brand-slot-nav_home button[phx-click="pick_brand"]))
    |> render_click()

    art =
      file_input(view, "#brand-upload-nav_home", :brand, [
        %{name: "claw.png", content: "png-bytes", type: "image/png"}
      ])

    render_upload(art, "claw.png")
    assert Brand.status("nav_home") == :custom

    view
    |> element(~s(#brand-slot-nav_home button[phx-click="clear_brand"]))
    |> render_click()

    assert Brand.status("nav_home") == :default
  end
end
