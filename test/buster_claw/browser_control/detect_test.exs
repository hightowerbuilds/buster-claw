defmodule BusterClaw.BrowserControl.DetectTest do
  # async: false — exercises the global :browser_control_binary override.
  use ExUnit.Case, async: false

  alias BusterClaw.BrowserControl.Detect

  setup do
    root = Path.join(System.tmp_dir!(), "bc_detect_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :browser_control_binary)
    Application.delete_env(:buster_claw, :browser_control_binary)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:buster_claw, :browser_control_binary, prev),
        else: Application.delete_env(:buster_claw, :browser_control_binary)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp fake_browser(root, name, mode \\ 0o755) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, mode)
    path
  end

  test "returns the first runnable candidate in order", %{root: root} do
    brave = fake_browser(root, "brave")
    edge = fake_browser(root, "edge")
    missing = Path.join(root, "chrome-not-installed")

    assert Detect.find([missing, brave, edge]) == {:ok, brave}
  end

  test "skips non-executable files", %{root: root} do
    plain = fake_browser(root, "chrome", 0o644)
    runnable = fake_browser(root, "chromium")

    assert Detect.find([plain, runnable]) == {:ok, runnable}
  end

  test "reports no_browser when nothing is runnable", %{root: root} do
    assert Detect.find([Path.join(root, "nope")]) == {:error, :no_browser}
  end

  test "a directory is not a browser", %{root: root} do
    dir = Path.join(root, "Google Chrome.app")
    File.mkdir_p!(dir)

    assert Detect.find([dir]) == {:error, :no_browser}
  end

  test "the configured override wins when runnable", %{root: root} do
    pinned = fake_browser(root, "pinned")
    candidate = fake_browser(root, "candidate")
    Application.put_env(:buster_claw, :browser_control_binary, pinned)

    assert Detect.find([candidate]) == {:ok, pinned}
  end

  test "a broken override falls back to detection", %{root: root} do
    candidate = fake_browser(root, "candidate")
    Application.put_env(:buster_claw, :browser_control_binary, Path.join(root, "gone"))

    assert Detect.find([candidate]) == {:ok, candidate}
  end

  test "default candidates are absolute and ordered Chrome-first" do
    candidates = Detect.candidates()

    assert Enum.all?(candidates, &(Path.type(&1) == :absolute))
    assert List.first(candidates) =~ "Google Chrome"
    # Detection order is a settled roadmap decision: Chrome → Brave → Edge → Chromium.
    order = ["Google Chrome", "Brave", "Edge", "Chromium"]

    positions =
      Enum.map(order, fn name ->
        Enum.find_index(candidates, &String.contains?(&1, name))
      end)

    assert positions == Enum.sort(positions)
    refute nil in positions
  end
end
