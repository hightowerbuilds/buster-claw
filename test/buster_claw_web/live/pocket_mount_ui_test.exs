defmodule BusterClawWeb.PocketMountUITest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.{Library, Pockets}
  alias BusterClaw.Pockets.Mounts

  setup do
    root = Path.join(System.tmp_dir!(), "bc_mountui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    target = Path.join(System.tmp_dir!(), "bc_mnt_tgt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "claw.png"), "png-bytes")

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
      File.rm_rf(target)
    end)

    {:ok, root: root, target: target}
  end

  defp open_pockets(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "select_home_tab", %{"tab" => "pockets"})
    view
  end

  defp create(view, name) do
    view |> element(~s(button[phx-click="toggle_new"])) |> render_click()
    view |> form("#pocket-new-form", %{"name" => name}) |> render_submit()
  end

  defp open(view, name) do
    view
    |> element(~s(button[phx-click="open_pocket"][phx-value-name="#{name}"]))
    |> render_click()
  end

  # The mount form only exists once "Mount…" is clicked — the tab stays two
  # levels and one screen, so the control expands rather than opening a panel.
  defp start_mount(view, name) do
    view
    |> element(~s(button[phx-click="toggle_mount"][phx-value-name="#{name}"]))
    |> render_click()
  end

  describe "New" do
    test "creates a Pocket that then appears in the list", %{conn: conn} do
      view = open_pockets(conn)
      assert has_element?(view, "#pockets-empty")

      create(view, "hazard-icons")

      assert has_element?(view, "#pocket-row-hazard-icons")
      assert File.exists?(Pockets.manifest_path("hazard-icons"))
      assert {:ok, %{name: "hazard-icons"}} = Pockets.load("hazard-icons")
    end

    test "a bad name is refused in words, and nothing is created", %{conn: conn} do
      view = open_pockets(conn)

      html = create(view, "Has Spaces")

      assert html =~ "lowercase letters, digits or hyphens"

      # Narrowed 08-15: this was `Pockets.list() == []`, which is a universal
      # over the whole catalog standing in for a claim about ONE name. Opening
      # the tab now creates the Dock icon's Pocket on demand, and the universal
      # failed for a reason that has nothing to do with what this test is about.
      # The precise claim is that the refused name was not created.
      refute "Has Spaces" in Enum.map(Pockets.list(), & &1.name)
      refute "has-spaces" in Enum.map(Pockets.list(), & &1.name)
    end
  end

  describe "Mount" do
    test "mounts a Pocket at a folder and reads its files", %{conn: conn, target: target} do
      view = open_pockets(conn)
      create(view, "art")
      open(view, "art")
      start_mount(view, "art")

      view
      |> form("#pocket-mount-art", %{"name" => "art", "path" => target})
      |> render_submit()

      assert Mounts.mounted?("art")
      assert {:ok, pocket} = Pockets.load("art")
      assert {:mounted, ^target, false} = pocket.binding

      # The mount is what makes the outside file readable at all.
      assert [%{name: "claw.png"}] = Pockets.contents(pocket)
      assert Pockets.resolve(pocket, "claw.png")
    end

    test "the mounted Pocket is marked, and its location is shown", %{conn: conn, target: target} do
      view = open_pockets(conn)
      create(view, "art")
      open(view, "art")
      start_mount(view, "art")
      view |> form("#pocket-mount-art", %{"name" => "art", "path" => target}) |> render_submit()

      html = render(view)
      assert html =~ "↗"
      assert html =~ target
    end

    test "writable is off unless it is ticked", %{conn: conn, target: target} do
      view = open_pockets(conn)
      create(view, "art")
      open(view, "art")
      start_mount(view, "art")

      view
      |> form("#pocket-mount-art", %{"name" => "art", "path" => target, "writable" => "true"})
      |> render_submit()

      assert {:ok, %{writable: true}} = Mounts.fetch("art")
    end

    test "unmounting leaves every file exactly where it is", %{conn: conn, target: target} do
      view = open_pockets(conn)
      create(view, "art")
      open(view, "art")
      start_mount(view, "art")
      view |> form("#pocket-mount-art", %{"name" => "art", "path" => target}) |> render_submit()
      assert Mounts.mounted?("art")

      view
      |> element(~s(button[phx-click="unmount_pocket"][phx-value-name="art"]))
      |> render_click()

      refute Mounts.mounted?("art")
      # The asymmetry that makes unmount and delete different words.
      assert File.exists?(Path.join(target, "claw.png"))
      assert {:ok, %{binding: :local}} = Pockets.load("art")
    end
  end

  describe "every refusal reaches the operator in words" do
    setup %{conn: conn} do
      view = open_pockets(conn)
      create(view, "art")
      open(view, "art")
      start_mount(view, "art")
      {:ok, view: view}
    end

    test "a relative path", %{view: view} do
      html =
        view |> form("#pocket-mount-art", %{"name" => "art", "path" => "art"}) |> render_submit()

      assert html =~ "full path, starting with /"
    end

    test "a folder that is not there", %{view: view} do
      html =
        view
        |> form("#pocket-mount-art", %{"name" => "art", "path" => "/nope/definitely/not"})
        |> render_submit()

      assert html =~ "no folder at that path"
    end

    test "a file rather than a folder", %{view: view, root: root} do
      file = Path.join(root, "a-file.txt")
      File.write!(file, "x")

      html =
        view |> form("#pocket-mount-art", %{"name" => "art", "path" => file}) |> render_submit()

      assert html =~ "a file, not a folder"
    end

    test "the home directory itself", %{view: view} do
      html =
        view
        |> form("#pocket-mount-art", %{"name" => "art", "path" => System.user_home()})
        |> render_submit()

      assert html =~ "too broad"
    end
  end

  test "an app-owned Pocket offers no way to mount it away", %{conn: conn, target: target} do
    # Give the backgrounds Pocket a manifest the way an upload would, BEFORE the
    # tab loads its list.
    :ok =
      Pockets.ensure_pocket("backgrounds", %{
        kind: :media,
        description: "Background images you uploaded.",
        roles: ["background"]
      })

    view = open_pockets(conn)
    open(view, "backgrounds")
    start_mount(view, "backgrounds")

    html =
      view
      |> form("#pocket-mount-backgrounds", %{"name" => "backgrounds", "path" => target})
      |> render_submit()

    assert html =~ "has to stay in the workspace"
    refute Mounts.mounted?("backgrounds")
  end
end
