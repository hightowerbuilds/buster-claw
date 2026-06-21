defmodule BusterClaw.SkillsTest do
  # async: false — points the global :workspace_root / :library_root at tmp dirs.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Commands, Library, Sentinel, Skills}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_skills_#{System.unique_integer([:positive])}")
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

  defp write_skill(root, name, content) do
    dir = Path.join(root, "skills")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".md"), content)
  end

  defp save_note(opts \\ []) do
    tier = Keyword.get(opts, :tier, "restricted")
    enabled = Keyword.get(opts, :enabled, true)

    """
    ---
    name: save-note
    description: Save a quick note to the Library.
    tier: #{tier}
    enabled: #{enabled}
    handler_kind: composition
    args: {"title":{"type":"string"},"body":{"type":"string"}}
    steps: [{"command":"document_save","args":{"name":"$title","body":"$body"}}]
    ---

    # save-note
    """
  end

  # --- loader / validation ----------------------------------------------

  test "fetch loads an enabled, valid composition skill", %{root: root} do
    write_skill(root, "save-note", save_note(tier: "safe"))

    assert {:ok, skill} = Skills.fetch("save-note")
    assert skill.name == "save-note"
    assert skill.tier == :safe
    assert skill.handler_kind == :composition
    assert [%{"command" => "document_save"}] = skill.steps
  end

  test "a disabled skill is non-resolvable", %{root: root} do
    write_skill(root, "save-note", save_note(enabled: false))

    assert :error = Skills.fetch("save-note")
    assert {:error, :unknown_command} = Commands.call("save-note", %{})
  end

  test "an unsupported handler_kind is rejected", %{root: root} do
    write_skill(root, "scripty", """
    ---
    name: scripty
    enabled: true
    handler_kind: script
    steps: [{"command":"document_list"}]
    ---
    """)

    assert {:error, {:unsupported_handler_kind, "script"}} = Skills.load("scripty")
    assert :error = Skills.fetch("scripty")
  end

  test "a skill exceeding max_steps is rejected", %{root: root} do
    steps = List.duplicate(%{"command" => "document_list"}, 21) |> Jason.encode!()

    write_skill(root, "huge", """
    ---
    name: huge
    enabled: true
    handler_kind: composition
    steps: #{steps}
    ---
    """)

    assert {:error, :too_many_steps} = Skills.load("huge")
  end

  test "a name that disagrees with the filename stem is rejected", %{root: root} do
    write_skill(root, "real-name", """
    ---
    name: other-name
    enabled: true
    handler_kind: composition
    steps: [{"command":"document_list"}]
    ---
    """)

    assert {:error, :name_mismatch} = Skills.load("real-name")
  end

  # --- catalog visibility -----------------------------------------------

  test "enabled skills are listed via list_skills/0 marked source: :composition", %{root: root} do
    write_skill(root, "save-note", save_note())

    entry = Enum.find(Commands.list_skills(), &(&1.name == "save-note"))
    assert entry.source == :composition

    # The native catalog invariant is untouched: skills are not in list_commands/0.
    refute Enum.any?(Commands.list_commands(), &(&1.name == "save-note"))
  end

  # --- execution ---------------------------------------------------------

  test "Commands.call runs an enabled composition skill end to end", %{root: root} do
    write_skill(root, "save-note", save_note())

    {:ok, before} = Commands.document_list(%{})

    assert {:ok, [%{command: "document_save", result: result}]} =
             Commands.call("save-note", %{"title" => "Hello", "body" => "World"},
               caller: :trusted
             )

    refute is_nil(result)

    {:ok, docs} = Commands.document_list(%{})
    assert length(docs) == length(before) + 1
    assert Enum.any?(docs, &(&1.name == "Hello")), "step args $title/$body should interpolate"
  end

  # --- threat-model invariants ------------------------------------------

  test "a restricted skill is refused for an :mcp caller", %{root: root} do
    write_skill(root, "save-note", save_note(tier: "restricted"))

    assert {:error, :requires_confirmation} =
             Commands.call("save-note", %{"title" => "x", "body" => "y"}, caller: :mcp)

    assert Enum.any?(Sentinel.list_events(), &(&1.category == "security_block")),
           "a refused skill must hit the Sentinel feed"
  end

  test "a skill cannot reach a gated command as :agent_untrusted", %{root: root} do
    write_skill(root, "purge", """
    ---
    name: purge
    description: tries to delete
    tier: restricted
    enabled: true
    handler_kind: composition
    steps: [{"command":"document_delete","args":{"id":1}}]
    ---
    """)

    assert {:error, {:step_failed, "document_delete", :requires_confirmation}} =
             Commands.call("purge", %{}, caller: :agent_untrusted)
  end
end
