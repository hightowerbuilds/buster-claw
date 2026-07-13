defmodule BusterClaw.TrustedNumbersTest do
  # async: false — mutates the global :workspace_root to point at a tmp policy file.
  use ExUnit.Case, async: false

  alias BusterClaw.TrustedNumbers

  setup do
    root = Path.join(System.tmp_dir!(), "bc_trusted_num_#{System.unique_integer([:positive])}")
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
    File.write!(Path.join(root, "memory/trusted-phone-numbers.md"), contents)
    # The parsed policy is cached in :persistent_term; a direct file write bypasses
    # the add/remove cache refresh, so drop the key the way a fresh boot would.
    :persistent_term.erase(
      {TrustedNumbers, :policy, Path.join(root, "memory/trusted-phone-numbers.md")}
    )
  end

  describe "normalize/1" do
    test "accepts the common US shapes and lands them all on one E.164 form" do
      for raw <- [
            "+18446878016",
            "18446878016",
            "8446878016",
            "844-687-8016",
            "(844) 687-8016",
            "+1 (844) 687-8016",
            " 844.687.8016 "
          ] do
        assert TrustedNumbers.normalize(raw) == {:ok, "+18446878016"}, "failed on #{inspect(raw)}"
      end
    end

    test "honours a full international number as written" do
      assert TrustedNumbers.normalize("+442071838750") == {:ok, "+442071838750"}
    end

    test "refuses ambiguous digit strings rather than guessing a country code" do
      # 8 digits, no +: could be anything. Guessing here is how a date becomes a
      # trusted caller.
      assert TrustedNumbers.normalize("20260712") == :error
      assert TrustedNumbers.normalize("2026-07-12") == :error
      assert TrustedNumbers.normalize("12345") == :error
      assert TrustedNumbers.normalize("not a phone") == :error
      assert TrustedNumbers.normalize("") == :error
    end
  end

  describe "match/1" do
    test "trusts a listed number written in any shape", %{root: root} do
      write_policy(root, "# Trusted\n\n- (844) 687-8016\n")

      assert TrustedNumbers.trusted?("+18446878016")
      assert TrustedNumbers.trusted?("8446878016")
      assert TrustedNumbers.match("+1 844 687 8016") == "+18446878016"
    end

    test "an unlisted caller is untrusted", %{root: root} do
      write_policy(root, "# Trusted\n\n- +18446878016\n")

      refute TrustedNumbers.trusted?("+15551234567")
      assert TrustedNumbers.match("+15551234567") == nil
    end

    test "a missing policy file trusts nobody", %{root: root} do
      File.rm_rf!(Path.join(root, "memory"))
      refute TrustedNumbers.trusted?("+18446878016")
    end

    test "an empty policy file trusts nobody", %{root: root} do
      write_policy(root, "")
      refute TrustedNumbers.trusted?("+18446878016")
    end

    test "garbage input never matches", %{root: root} do
      write_policy(root, "- +18446878016\n")

      refute TrustedNumbers.trusted?(nil)
      refute TrustedNumbers.trusted?("")
      refute TrustedNumbers.trusted?("unknown")
    end
  end

  describe "the seeded policy" do
    test "trusts nobody — its example placeholder must not parse as a live entry" do
      # The scanner reads the whole file (no fence/comment stripping), so any
      # phone-shaped example in the seed would silently seed a trusted caller and
      # contradict the safe default. This is the regression guard for that.
      assert TrustedNumbers.seed_contents() |> parse_via_policy() == []
    end

    defp parse_via_policy(contents) do
      root = Path.join(System.tmp_dir!(), "bc_seed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "memory"))
      prev = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)
      File.write!(Path.join(root, "memory/trusted-phone-numbers.md"), contents)

      entries = TrustedNumbers.list_entries()

      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
      entries
    end
  end

  describe "add_entry/remove_entry" do
    test "adds, normalizes, is idempotent, and takes effect immediately", %{root: root} do
      write_policy(root, "# Trusted\n")

      refute TrustedNumbers.trusted?("+18446878016")

      assert {:ok, "+18446878016"} = TrustedNumbers.add_entry("(844) 687-8016")
      assert TrustedNumbers.trusted?("+18446878016")
      assert TrustedNumbers.list_entries() == ["+18446878016"]

      # Same number, different shape — no duplicate.
      assert {:ok, "+18446878016"} = TrustedNumbers.add_entry("844-687-8016")
      assert TrustedNumbers.list_entries() == ["+18446878016"]
    end

    test "removes by any equivalent form", %{root: root} do
      write_policy(root, "# Trusted\n\n- +18446878016\n")
      assert TrustedNumbers.trusted?("+18446878016")

      assert :ok = TrustedNumbers.remove_entry("(844) 687-8016")

      refute TrustedNumbers.trusted?("+18446878016")
      assert TrustedNumbers.list_entries() == []
    end

    test "refuses an entry it cannot normalize", %{root: root} do
      write_policy(root, "# Trusted\n")

      assert {:error, :invalid_entry} = TrustedNumbers.add_entry("not a number")
      assert {:error, :invalid_entry} = TrustedNumbers.remove_entry("12345")
      assert TrustedNumbers.list_entries() == []
    end
  end
end
