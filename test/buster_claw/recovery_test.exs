defmodule BusterClaw.RecoveryTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Recovery

  test "recovery_key/0 returns the configured Phoenix secret_key_base" do
    expected = Application.get_env(:buster_claw, BusterClawWeb.Endpoint)[:secret_key_base]
    assert is_binary(expected)
    assert Recovery.recovery_key() == expected
  end

  test "restore_file_path/0 sits under the data dir and is named RESTORE_SECRET_KEY" do
    assert Recovery.restore_file_path() == Path.join(Recovery.data_dir(), "RESTORE_SECRET_KEY")
    assert Path.basename(Recovery.restore_file_path()) == "RESTORE_SECRET_KEY"
  end

  test "data_dir/0 is an absolute BusterClaw path" do
    dir = Recovery.data_dir()
    assert Path.type(dir) == :absolute
    assert String.contains?(dir, "BusterClaw")
  end
end
