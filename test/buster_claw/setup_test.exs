defmodule BusterClaw.SetupTest do
  # async: false because the launcher-missing assertion overrides the global
  # `:workspace_root` application env.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Settings
  alias BusterClaw.Setup

  setup do
    # Point the workspace at an empty tmp dir so the `buster-claw` launcher is
    # guaranteed absent (keeps `tools_complete?` deterministic regardless of the
    # host's real workspace).
    root =
      Path.join(System.tmp_dir!(), "buster-claw-setup-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)

    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))

    on_exit(fn ->
      if prev_ws,
        do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
        else: Application.delete_env(:buster_claw, :workspace_root)

      if prev_lib,
        do: Application.put_env(:buster_claw, :library_root, prev_lib),
        else: Application.delete_env(:buster_claw, :library_root)

      File.rm_rf(root)
    end)

    :ok
  end

  test "status reports four tracked steps" do
    status = Setup.status()
    assert status.total == 4
    assert length(status.steps) == 4
    assert Enum.map(status.steps, & &1.key) == [:workspace, :tools, :google, :live]
  end

  test "fresh install reports 0 of 4 complete" do
    status = Setup.status()
    assert status.completed == 0
    refute status.complete?
  end

  test "workspace completes only after explicit confirmation" do
    refute Setup.workspace_complete?()
    Settings.put("workspace_confirmed", "true")
    assert Setup.workspace_complete?()
  end

  test "tools is incomplete when the launcher file is missing" do
    # The workspace root from setup/0 has no launcher installed.
    refute File.exists?(BusterClaw.WorkspaceCLI.launcher_path())
    refute Setup.tools_complete?()

    # Regardless of the host environment, the predicate is always a boolean.
    assert is_boolean(Setup.tools_complete?())
  end

  test "live flips true after mark_went_live/0" do
    refute Setup.live_complete?()
    Setup.mark_went_live()
    assert Setup.live_complete?()
  end
end
