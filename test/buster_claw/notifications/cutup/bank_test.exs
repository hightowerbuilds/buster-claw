defmodule BusterClaw.Notifications.Cutup.BankTest do
  @moduledoc """
  `Cutup.Bank` — the voice partition `STUDIO_ROADMAP` V.0 requires.

  Uses the DataCase because the roster lives in `Settings` (the app database),
  unlike the rest of the `Cutup` suites, which are deliberately database-free.
  That asymmetry is itself load-bearing and is asserted below: `Bank.of/1` must
  never reach the roster, because it is called once per index file inside
  `Index.load/1` and would put an Ecto query in the middle of a pure module.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Cutup.Bank
  alias BusterClaw.Notifications.Cutup.Gaps
  alias BusterClaw.Notifications.Cutup.Index

  setup do
    root = Path.join(System.tmp_dir!(), "bc_bank_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "the default bank" do
    test "exists with no configuration at all" do
      assert Bank.default() == "voicemail"
      assert [%{name: "voicemail"}] = Bank.list()
      assert Bank.active() == "voicemail"
    end

    test "is always first, so the selector opens on the corpus that exists" do
      {:ok, _} = Bank.create("aardvark")
      {:ok, _} = Bank.create("zebra")

      assert ["voicemail", "aardvark", "zebra"] = Enum.map(Bank.list(), & &1.name)
    end

    test "cannot be created over or deleted" do
      assert {:error, :reserved_name} = Bank.create("voicemail")
      assert {:error, :reserved_name} = Bank.delete("voicemail", false)
    end
  end

  describe "names" do
    test "a typed label becomes a usable name rather than a refusal" do
      assert {:ok, "aunt-mary"} = Bank.safe_name("  Aunt Mary  ")
    end

    test "refuses what it cannot make safe instead of mangling it into a different name" do
      for bad <- ["", "   ", "../etc", "voice/mail", "-leading", "a" <> String.duplicate("b", 40)] do
        assert {:error, :invalid_name} = Bank.safe_name(bad), "expected #{inspect(bad)} refused"
      end
    end

    test "a name with a path separator can never become a bank" do
      assert {:error, :invalid_name} = Bank.create("../../escape")
      refute Enum.any?(Bank.list(), &String.contains?(&1.name, "/"))
    end
  end

  describe "create and select" do
    test "a new bank is empty, and that is a valid state" do
      assert {:ok, %{name: "luke", label: "Luke"}} = Bank.create("luke", "Luke")
      assert Bank.known?("luke")
    end

    test "an unlabelled bank reads as its name rather than blank" do
      assert {:ok, %{name: "sam", label: "sam"}} = Bank.create("sam")
      assert {:ok, %{label: "kim"}} = Bank.create("kim", "   ")
    end

    test "creating the same bank twice is refused, not silently merged" do
      {:ok, _} = Bank.create("luke")
      assert {:error, :already_exists} = Bank.create("luke")
    end

    test "selecting an unknown bank is refused rather than creating one" do
      assert {:error, :not_found} = Bank.set_active("nobody")
      assert Bank.active() == "voicemail"
    end

    test "the active bank survives a round trip" do
      {:ok, _} = Bank.create("luke")
      assert {:ok, "luke"} = Bank.set_active("luke")
      assert Bank.active() == "luke"
    end
  end

  describe "a dangling active pointer" do
    test "falls back to the default rather than reporting an empty corpus" do
      {:ok, _} = Bank.create("luke")
      {:ok, "luke"} = Bank.set_active("luke")
      :ok = Bank.delete("luke", Gaps.bank_in_use?("luke"))

      assert Bank.active() == "voicemail"
    end
  end

  describe "delete refuses a bank that still holds takes" do
    test "bank_in_use, so no take is ever orphaned from its roster entry" do
      {:ok, _} = Bank.create("luke")
      index_in("luke", "hello.wav")

      assert {:error, :bank_in_use} = Bank.delete("luke", Gaps.bank_in_use?("luke"))
      assert Bank.known?("luke")
    end

    test "and allows it once the index naming it is gone" do
      {:ok, _} = Bank.create("luke")
      index_in("luke", "hello.wav")
      :ok = Index.delete("hello.wav")

      assert :ok = Bank.delete("luke", Gaps.bank_in_use?("luke"))
    end
  end

  describe "of/1 reads the shape, never the roster" do
    # The load-bearing one. If this ever consults `Settings`, `Index.load/1`
    # acquires a database query per file and 46 Cutup tests fail — which is how
    # the first version of this module was caught.
    test "a well-formed name survives even when the bank is not on the roster" do
      refute Bank.known?("ghost")
      assert Bank.of(%{bank: "ghost"}) == "ghost"
      assert Bank.of(%{"bank" => "ghost"}) == "ghost"
    end

    test "deleting a bank does not silently re-file its takes into the default" do
      {:ok, _} = Bank.create("luke")
      index_in("luke", "hello.wav")
      :ok = Index.delete("hello.wav")
      :ok = Bank.delete("luke", Gaps.bank_in_use?("luke"))

      # The attribution is a property of the file, not of the roster.
      assert Bank.of(%{bank: "luke"}) == "luke"
    end

    test "anything malformed reads as the default, so a take is never bankless" do
      for bad <- [%{}, %{bank: nil}, %{bank: 7}, %{bank: "../etc"}, %{bank: ""}, "nonsense"] do
        assert Bank.of(bad) == "voicemail", "expected #{inspect(bad)} to read as default"
      end
    end
  end

  defp index_in(bank, source) do
    {:ok, index} =
      Index.build(source, [%{text: "hello", start_ms: 0, end_ms: 300}], bank: bank)

    :ok = Index.save(index)
  end
end
