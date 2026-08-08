defmodule BusterClaw.Commands.ExtensionsTest do
  # async: false — points the global :workspace_root / :library_root at tmp dirs.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Commands, Extensions, Library, Skills}

  @bundled "trading-robinhood"

  setup do
    root = Path.join(System.tmp_dir!(), "bc_extcmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "reads" do
    test "extension_list reports the shipped extension and its declared reach" do
      assert {:ok, list} = Commands.call("extension_list", %{}, caller: :trusted)
      entry = Enum.find(list, &(&1.id == @bundled))

      assert entry.money
      assert entry.network == ["agent.robinhood.com"]
      assert entry.writes == ["order_cancel"]
    end

    test "extension_show returns the manifest body and part list" do
      assert {:ok, shown} = Commands.call("extension_show", %{"id" => @bundled}, caller: :trusted)

      assert shown.name == "Robinhood Trading"
      refute shown.enabled
      assert shown.body =~ "It cannot place or amend an order"
    end

    test "an unknown extension is an error, not an empty success" do
      assert {:error, :not_found} =
               Commands.call("extension_show", %{"id" => "nope"}, caller: :trusted)
    end
  end

  describe "enable is the consent moment" do
    test "enable then disable, through the command surface" do
      assert {:ok, %{enabled: @bundled}} =
               Commands.call("extension_enable", %{"id" => @bundled}, caller: :trusted)

      assert Extensions.enabled?(@bundled)

      assert {:ok, %{disabled: @bundled}} =
               Commands.call("extension_disable", %{"id" => @bundled}, caller: :trusted)

      refute Extensions.enabled?(@bundled)
    end

    test "an untrusted agent is refused enable, and it does NOT take effect" do
      assert {:error, :requires_confirmation} =
               Commands.call("extension_enable", %{"id" => @bundled}, caller: :agent_untrusted)

      refute Extensions.enabled?(@bundled)
    end

    test "an mcp caller cannot enable an extension" do
      assert {:error, :requires_confirmation} =
               Commands.call("extension_enable", %{"id" => @bundled}, caller: :mcp)

      refute Extensions.enabled?(@bundled)
    end

    test "disable is NOT gated — removing capability never waits for approval" do
      {:ok, _} = Commands.call("extension_enable", %{"id" => @bundled}, caller: :trusted)

      assert {:ok, %{disabled: @bundled}} =
               Commands.call("extension_disable", %{"id" => @bundled}, caller: :agent_untrusted)

      refute Extensions.enabled?(@bundled)
    end
  end

  describe "extension_add_part" do
    setup do
      {:ok, _} = Commands.call("extension_enable", %{"id" => @bundled}, caller: :trusted)
      :ok
    end

    test "writes a disabled part and says so" do
      assert {:ok, result} =
               Commands.call(
                 "extension_add_part",
                 %{
                   "id" => @bundled,
                   "name" => "position-summary",
                   "description" => "Summarize one account's positions.",
                   "body" => "Read the account, then summarize its positions."
                 },
                 caller: :trusted
               )

      assert result.enabled == false
      assert result.note =~ "disabled"
      assert File.read!(result.path) =~ "enabled: false"

      # Inert until a person enables it.
      assert Skills.fetch("position-summary") == :error
    end

    test "an unparseable part is removed rather than left behind" do
      # A composition kind whose steps are absent fails Skills validation. The
      # file must not survive as a broken instruction in an extension directory.
      assert {:error, _reason} =
               Commands.call(
                 "extension_add_part",
                 %{
                   "id" => @bundled,
                   "name" => "half-written",
                   "body" => "Body.",
                   "kind" => "composition",
                   "steps" => []
                 },
                 caller: :trusted
               )

      refute File.exists?(Extensions.part_path(@bundled, "half-written"))
    end

    test "an mcp caller cannot attach a part" do
      assert {:error, :requires_confirmation} =
               Commands.call(
                 "extension_add_part",
                 %{"id" => @bundled, "name" => "sneaky", "body" => "Body."},
                 caller: :mcp
               )

      refute File.exists?(Extensions.part_path(@bundled, "sneaky"))
    end

    test "an untrusted agent MAY attach a part — because a part grants nothing" do
      # This is deliberate, and the reason it is safe is the disabled gate: the
      # part is a proposal in a file, not a capability. Attaching one changes
      # nothing until a person reads it and turns it on.
      assert {:ok, result} =
               Commands.call(
                 "extension_add_part",
                 %{"id" => @bundled, "name" => "proposed", "body" => "Body."},
                 caller: :agent_untrusted
               )

      assert result.enabled == false
      assert Skills.fetch("proposed") == :error
    end

    test "it cannot write outside the extension's parts directory" do
      assert {:error, :invalid_name} =
               Commands.call(
                 "extension_add_part",
                 %{"id" => @bundled, "name" => "../../escape", "body" => "Body."},
                 caller: :trusted
               )
    end

    test "missing args are refused" do
      assert {:error, :missing_args} =
               Commands.call("extension_add_part", %{"id" => @bundled}, caller: :trusted)
    end
  end
end
