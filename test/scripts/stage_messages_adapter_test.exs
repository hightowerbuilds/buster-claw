defmodule BusterClaw.StageMessagesAdapterTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/stage_messages_adapter.sh", __DIR__)

  test "a corrupt cached archive is refused before extraction or execution" do
    root = Path.join(System.tmp_dir!(), "imsg-stage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, "tmp/imessage-spike"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(@script, Path.join(root, "scripts/stage_messages_adapter.sh"))
    File.write!(Path.join(root, "tmp/imessage-spike/imsg-macos.zip"), "unverified archive")

    {output, status} =
      System.cmd("bash", [Path.join(root, "scripts/stage_messages_adapter.sh")],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "checksum mismatch"
    refute File.exists?(Path.join(root, "priv/messages"))
  end

  test "build pin agrees with the protocol validator" do
    assert File.read!(@script) =~ ~s(VERSION="#{BusterClaw.Messages.Status.version()}")
  end
end
