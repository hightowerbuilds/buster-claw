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

  describe "managing entries" do
    test "list_entries returns addresses and domain wildcards, sorted", %{root: root} do
      write_policy(root, "# Trusted\n\n- bob@example.com\n- *@acme.com\n- alice@example.com\n")

      assert TrustedSenders.list_entries() == [
               %{type: :address, value: "alice@example.com"},
               %{type: :address, value: "bob@example.com"},
               %{type: :domain, value: "*@acme.com"}
             ]
    end

    test "add_entry appends an address and is idempotent", %{root: _root} do
      assert {:ok, "alice@example.com"} = TrustedSenders.add_entry("Alice@Example.com")
      assert TrustedSenders.trusted?("alice@example.com")

      # adding again does not duplicate
      assert {:ok, "alice@example.com"} = TrustedSenders.add_entry("alice@example.com")
      assert [%{value: "alice@example.com"}] = TrustedSenders.list_entries()
    end

    test "add_entry accepts a wildcard and a bare domain (as a wildcard)", %{root: _root} do
      assert {:ok, "*@acme.com"} = TrustedSenders.add_entry("*@acme.com")
      assert {:ok, "*@beta.io"} = TrustedSenders.add_entry("beta.io")

      assert TrustedSenders.trusted?("anyone@acme.com")
      assert TrustedSenders.trusted?("anyone@beta.io")
    end

    test "add_entry rejects junk", %{root: _root} do
      assert {:error, :invalid_entry} = TrustedSenders.add_entry("not-an-email")
      assert {:error, :invalid_entry} = TrustedSenders.add_entry("   ")
      assert TrustedSenders.list_entries() == []
    end

    test "remove_entry drops an entry without touching the others", %{root: root} do
      write_policy(root, "# Trusted\n\n- alice@example.com\n- bob@example.com\n- *@acme.com\n")

      assert :ok = TrustedSenders.remove_entry("alice@example.com")

      refute TrustedSenders.trusted?("alice@example.com")
      assert TrustedSenders.trusted?("bob@example.com")
      assert TrustedSenders.trusted?("x@acme.com")

      # a wildcard can be removed too (via any equivalent form)
      assert :ok = TrustedSenders.remove_entry("acme.com")
      refute TrustedSenders.trusted?("x@acme.com")
    end
  end
end
