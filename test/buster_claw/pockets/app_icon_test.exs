defmodule BusterClaw.Pockets.AppIconTest do
  @moduledoc """
  The macOS Dock icon as a Pocket — `APP_ICON_ROADMAP`, Phase 0 option 2.

  The property under test is the gap: **a file in the Pocket is not an icon.**
  An agent needs no command to write into a Pocket, so a slot that simply
  followed its folder would hand an unattended run the app's identity in the OS
  chrome. Everything here is a way of asking whether that gap holds.
  """
  # async: false — points the global :workspace_root at a tmp dir and writes
  # app_settings rows through the shared Settings store.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Library
  alias BusterClaw.Pockets
  alias BusterClaw.Pockets.AppIcon

  setup do
    root = Path.join(System.tmp_dir!(), "bc_appicon_#{System.unique_integer([:positive])}")
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

    AppIcon.ensure()
    {:ok, root: root}
  end

  # Straight into the folder, the way Finder does it — and the way an agent
  # with workspace write does it. This bypasses the app entirely, which is the
  # whole case this feature exists to hold.
  defp drop(name, bytes \\ "icon-bytes") do
    File.write!(Path.join(Pockets.pocket_dir(AppIcon.pocket()), name), bytes)
  end

  describe "the gap between a file and an icon" do
    test "an empty Pocket makes no call at all" do
      assert AppIcon.status() == :empty

      # nil is "leave the bundle icon alone", NOT "load the shipped PNG". The
      # bundle icon already is the default; the absence of a call is how it shows.
      assert AppIcon.current_path() == nil
    end

    test "dropping a file in changes nothing until it is applied" do
      drop("claw.png")

      assert AppIcon.status() == :pending

      assert AppIcon.current_path() == nil,
             "a file in the Pocket must not reach the Dock on its own"

      assert {:ok, path} = AppIcon.apply_icon()
      assert AppIcon.status() == :applied
      assert AppIcon.current_path() == path
      assert Path.basename(path) == "claw.png"
    end

    test "replacing the file after applying puts the shipped icon back" do
      drop("claw.png")
      {:ok, _} = AppIcon.apply_icon()

      # The attack this is keyed against: swap the bytes under a choice the
      # operator made about something else. A store keyed on the FILENAME would
      # still say applied and would show art nobody agreed to.
      drop("claw.png", "different-bytes")

      assert AppIcon.status() == :replaced
      assert AppIcon.current_path() == nil
    end

    test "re-applying after a replacement is how it comes back" do
      drop("claw.png")
      {:ok, _} = AppIcon.apply_icon()
      drop("claw.png", "different-bytes")
      assert AppIcon.status() == :replaced

      assert {:ok, _} = AppIcon.apply_icon()
      assert AppIcon.status() == :applied
      refute AppIcon.current_path() == nil
    end

    test "revoking keeps the file and drops only the choice" do
      drop("claw.png")
      {:ok, path} = AppIcon.apply_icon()

      :ok = AppIcon.revoke()

      assert AppIcon.status() == :pending
      assert AppIcon.current_path() == nil
      assert File.exists?(path), "revoking must not delete art the operator made"
    end
  end

  describe "states that are not an icon" do
    test "two images apply nothing and say how many" do
      drop("one.png")
      drop("two.png")

      assert AppIcon.status() == {:error, :too_many, 2}
      assert AppIcon.current_path() == nil
      assert {:error, {:too_many, 2}} = AppIcon.apply_icon()
    end

    test "an over-full Pocket cannot ride in on an earlier approval" do
      drop("claw.png")
      {:ok, _} = AppIcon.apply_icon()

      drop("second.png")

      # Still approved by hash, but there is no longer one image to mean it.
      assert AppIcon.status() == {:error, :too_many, 2}
      assert AppIcon.current_path() == nil
    end

    test "applying an empty Pocket is refused rather than silently clearing" do
      assert {:error, :no_image} = AppIcon.apply_icon()
      assert AppIcon.status() == :empty
    end

    test "a non-image file is not an image" do
      drop("notes.txt")
      drop("icon.svg")

      # SVG is deliberately absent from this list where `Brand` accepts it:
      # NSImage does not read one, so offering it would promise a Dock icon that
      # silently never appears.
      assert AppIcon.status() == :empty
      assert {:error, :no_image} = AppIcon.apply_icon()
    end
  end

  describe "the change broadcast" do
    test "applying and revoking both reach subscribers" do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, AppIcon.topic())
      drop("claw.png")

      {:ok, _} = AppIcon.apply_icon()
      assert_receive :app_icon_changed

      :ok = AppIcon.revoke()
      assert_receive :app_icon_changed
    end
  end
end
