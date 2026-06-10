defmodule BusterClaw.TrustedSendersTest do
  # async: false — mutates the global :workspace_root to point at a tmp policy file.
  use ExUnit.Case, async: false

  alias BusterClaw.TrustedSenders

  setup do
    root = Path.join(System.tmp_dir!(), "bc_trusted_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_policy(root, contents) do
    File.write!(Path.join(root, "memory/trusted-email-senders.md"), contents)
  end

  test "trusts a listed address, case-insensitively and from a header form", %{root: root} do
    write_policy(root, "# Trusted\n\n- alice@example.com\n")

    assert TrustedSenders.trusted?("Alice <ALICE@example.com>")
    assert TrustedSenders.match("alice@example.com") == "alice@example.com"
  end

  test "trusts a whole domain via a wildcard entry", %{root: root} do
    write_policy(root, "- *@example.com\n")

    assert TrustedSenders.trusted?("Bob <bob@example.com>")
    assert TrustedSenders.match("bob@example.com") == "@example.com"
  end

  test "rejects unlisted senders", %{root: root} do
    write_policy(root, "- alice@example.com\n")

    refute TrustedSenders.trusted?("Mallory <mallory@evil.com>")
  end

  test "a missing policy file trusts nobody", %{root: _root} do
    refute TrustedSenders.trusted?("anyone@example.com")
  end
end
