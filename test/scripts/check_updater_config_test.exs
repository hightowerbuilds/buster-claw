defmodule BusterClaw.Scripts.CheckUpdaterConfigTest do
  @moduledoc """
  `scripts/check_updater_config.sh` — `UPDATE_ROADMAP` `G-46`, the guard that
  turns a several-minute Tauri riddle into a one-second sentence.

  The script is run for real, as a subprocess, against configs written to a temp
  directory. Nothing here builds anything: that the guard can be exercised
  without a build is the reason it is its own script rather than ten lines
  inside `build_desktop.sh`.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check_updater_config.sh", __DIR__)
  @real_conf Path.expand("../../desktop/tauri/tauri.conf.json", __DIR__)
  @build_script Path.expand("../../scripts/build_desktop.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "bc_updater_conf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # `key: nil` removes the variable rather than setting it empty, so a key in the
  # developer's own shell cannot leak in and turn the "no key" cases into
  # something else.
  defp run(conf, key) do
    env = [{"TAURI_SIGNING_PRIVATE_KEY", key}]
    System.cmd(@script, [conf], env: env, stderr_to_stdout: true)
  end

  defp conf(dir, name, map) do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(map))
    path
  end

  describe "with no signing key" do
    test "it passes and says nothing, whatever the config holds", %{dir: dir} do
      bare = conf(dir, "bare.json", %{"productName" => "x"})

      assert {"", 0} = run(bare, nil)
      # Empty is unset: CI passes an unset secret through as "".
      assert {"", 0} = run(bare, "")
      # A keyless build does not ask for updater artifacts, so even a config that
      # cannot be read is not this guard's business.
      assert {"", 0} = run(Path.join(dir, "missing.json"), nil)
    end
  end

  describe "with a signing key" do
    test "a plugins.updater block passes", %{dir: dir} do
      with_block =
        conf(dir, "with.json", %{
          "plugins" => %{"updater" => %{"endpoints" => ["https://example.test"], "pubkey" => "k"}}
        })

      assert {"", 0} = run(with_block, "key")
    end

    test "no block is refused, and the message names the gate and both ways out", %{dir: dir} do
      bare = conf(dir, "bare.json", %{"productName" => "x"})

      assert {out, 1} = run(bare, "key")

      assert out =~ "no plugins.updater block"
      assert out =~ "G-19a"
      # The riddle it replaces, quoted, so someone searching the Tauri error finds
      # this script.
      assert out =~ "plugins > updater doesn't exist"
      assert out =~ "unset TAURI_SIGNING_PRIVATE_KEY"
      assert out =~ "one-way door"
    end

    test "an updater that is present but not an object is still absent", %{dir: dir} do
      for value <- [nil, true, "yes", []] do
        path = conf(dir, "odd.json", %{"plugins" => %{"updater" => value}})

        assert {out, 1} = run(path, "key")
        assert out =~ "no plugins.updater block", "updater: #{inspect(value)} was accepted"
      end
    end

    test "a config that does not exist is a failure, not a pass", %{dir: dir} do
      assert {out, 1} = run(Path.join(dir, "missing.json"), "key")
      assert out =~ "does not exist"
    end
  end

  describe "against this repository" do
    # A review-forcing snapshot, not a universal. Today the real config has no
    # updater block, so a key in the environment MUST be refused -- that is the
    # exact trap `G-46` exists for. The day `G-19a` lands this fails, and that is
    # the point: whoever writes the block is made to come here, read that it is a
    # one-way door, and flip this assertion on purpose.
    test "the real tauri.conf.json has no updater block yet, so a key is refused" do
      assert {out, 1} = run(@real_conf, "key")
      assert out =~ "G-19a"
    end

    test "build_desktop.sh calls the guard before it builds anything" do
      script = File.read!(@build_script)

      guard = :binary.match(script, "scripts/check_updater_config.sh")
      assert guard != :nomatch, "build_desktop.sh no longer calls the guard"

      {guard_at, _len} = guard

      # "Before `mix release`, before Rust, before anything Apple sees."
      for marker <- [
            "==> Fetching prod dependencies",
            "==> Assembling Elixir release",
            "==> Building Tauri bundle",
            "APPLE_SIGNING_IDENTITY"
          ] do
        {marker_at, _} = :binary.match(script, marker)
        assert guard_at < marker_at, "the guard runs after #{inspect(marker)}"
      end
    end
  end
end
