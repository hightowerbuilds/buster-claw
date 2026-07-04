defmodule BusterClaw.AppearanceTest do
  # async: false — points the global :workspace_root at a tmp dir and writes
  # app_settings rows through the shared Settings store.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Appearance

  setup do
    root = Path.join(System.tmp_dir!(), "bc_appearance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  defp fake_image(ext \\ ".png") do
    path = Path.join(System.tmp_dir!(), "bc_src_#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, "img-bytes")
    path
  end

  test "starts with max_slots empty slots and no active background" do
    slots = Appearance.slots()
    assert length(slots) == Appearance.max_slots()
    assert Enum.all?(slots, &(&1.filled == false))
    assert Appearance.active_slot() == nil
    assert Appearance.terminal_background_url() == nil
    assert Appearance.next_empty_slot() == 1
  end

  test "the first saved image becomes active; later ones do not" do
    assert {:ok, url1} = Appearance.put_terminal_background(1, fake_image(), "a.png")
    assert Appearance.active_slot() == 1
    assert Appearance.terminal_background_url() == url1
    assert url1 =~ "/appearance/terminal-background/1?v="

    assert {:ok, _url2} = Appearance.put_terminal_background(2, fake_image(), "b.jpg")
    assert Appearance.active_slot() == 1
    assert Appearance.next_empty_slot() == 3

    [s1, s2 | _] = Appearance.slots()
    assert s1.filled and s1.active
    assert s2.filled and not s2.active
  end

  test "set_active_slot switches the active background; empty slot errors" do
    Appearance.put_terminal_background(1, fake_image(), "a.png")
    Appearance.put_terminal_background(2, fake_image(), "b.png")

    assert {:ok, url2} = Appearance.set_active_slot(2)
    assert Appearance.active_slot() == 2
    assert Appearance.terminal_background_url() == url2

    assert {:error, :empty_slot} = Appearance.set_active_slot(4)
  end

  test "clearing the active slot promotes the next filled slot, then clears" do
    Appearance.put_terminal_background(1, fake_image(), "a.png")
    Appearance.put_terminal_background(2, fake_image(), "b.png")
    Appearance.set_active_slot(2)

    assert :ok = Appearance.clear_slot(2)
    assert Appearance.active_slot() == 1
    assert Enum.at(Appearance.slots(), 1).filled == false

    assert :ok = Appearance.clear_slot(1)
    assert Appearance.active_slot() == nil
    assert Appearance.terminal_background_url() == nil
  end

  test "rejects unsupported types and out-of-range slots" do
    assert {:error, :unsupported_type} =
             Appearance.put_terminal_background(1, fake_image(".txt"), "a.txt")

    assert {:error, :invalid_slot} =
             Appearance.put_terminal_background(9, fake_image(), "a.png")
  end

  test "slot_image returns the path for a filled slot and nil otherwise" do
    Appearance.put_terminal_background(3, fake_image(), "a.png")
    assert Appearance.slot_image(3) |> File.regular?()
    assert Appearance.slot_image(1) == nil
    assert Appearance.slot_image(99) == nil
  end

  test "a tampered stored path can't escape the appearance dir" do
    {:ok, _} = Appearance.put_terminal_background(1, fake_image(), "a.png")
    assert Appearance.slot_image(1) |> File.regular?()

    # A real file outside the appearance dir, reachable only by traversing out.
    root = Application.get_env(:buster_claw, :workspace_root)
    outside = Path.join(root, "outside.png")
    File.write!(outside, "img-bytes")

    # Point the slot at it via a `..` path; the containment guard must reject it.
    BusterClaw.Settings.put("terminal_background_1_path", "appearance/../outside.png")
    assert Appearance.slot_image(1) == nil
  end
end
