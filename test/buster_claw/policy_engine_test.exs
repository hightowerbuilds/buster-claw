defmodule BusterClaw.PolicyEngineTest do
  # async: false — points the global :workspace_root at a tmp dir (per-path cache).
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Commands, PolicyEngine, Sentinel}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_policy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))
    File.mkdir_p!(Path.join(root, "library"))

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_policy(root, body) do
    File.write!(Path.join([root, "memory", "policy.md"]), body)
    PolicyEngine.reload()
  end

  defp req(attrs), do: Enum.into(attrs, %{name: "x", caller: :trusted})

  # --- parsing -----------------------------------------------------------

  test "parses deny/allow rules and ignores prose, bad callers, and comments" do
    rules =
      PolicyEngine.parse_rules("""
      # Command policy
      Some prose that is not a rule.

      - deny *_delete for any
      - allow gmail_search for agent_untrusted
      - deny gmail_* for agent_untrusted
      - deny something for nobody   # bad caller -> dropped
      - frobnicate everything       # not a rule

      <!--
      - deny example_rule for any   # inside a comment -> must NOT parse
      -->
      """)

    assert %{action: :deny, pattern: "*_delete", caller: :any} in rules
    assert %{action: :allow, pattern: "gmail_search", caller: :agent_untrusted} in rules
    assert %{action: :deny, pattern: "gmail_*", caller: :agent_untrusted} in rules
    refute Enum.any?(rules, &(&1.pattern == "example_rule")), "commented rule must not parse"
    refute Enum.any?(rules, &(&1.caller == :nobody))
    assert length(rules) == 3
  end

  test "the seeded default policy parses to zero live rules (examples are commented)" do
    assert PolicyEngine.parse_rules(PolicyEngine.default_policy()) == []
  end

  # --- baseline (unchanged behavior) ------------------------------------

  test "baseline: agent/mcp may run safe, not restricted", _ do
    assert :allow = PolicyEngine.check(req(name: "event_list", caller: :mcp, tier: :safe))

    assert {:confirm, meta} =
             PolicyEngine.check(req(name: "event_create", caller: :mcp, tier: :restricted))

    assert meta.policy == :baseline
  end

  test "baseline: agent_untrusted may not run a gated command", _ do
    assert {:confirm, _} =
             PolicyEngine.check(req(name: "gmail_send", caller: :agent_untrusted, gated: true))

    assert :allow =
             PolicyEngine.check(
               req(name: "document_save", caller: :agent_untrusted, gated: false)
             )
  end

  test "baseline: a trusted caller is unconstrained by default", _ do
    assert :allow =
             PolicyEngine.check(req(name: "gmail_send", caller: :trusted, gated: true))
  end

  # --- operator rules ----------------------------------------------------

  test "an operator deny blocks an otherwise-allowed command", %{root: root} do
    write_policy(root, "- deny gmail_send for trusted\n")

    assert {:block, meta} =
             PolicyEngine.check(req(name: "gmail_send", caller: :trusted, gated: true))

    assert meta.policy == :operator
  end

  test "a more specific allow overrides a broader deny", %{root: root} do
    write_policy(root, """
    - deny gmail_* for agent_untrusted
    - allow gmail_search for agent_untrusted
    """)

    # gmail_search has an exact allow that out-specifies the gmail_* deny.
    assert :allow =
             PolicyEngine.check(req(name: "gmail_search", caller: :agent_untrusted, tier: :safe))

    # gmail_read is only matched by the broader deny.
    assert {:block, _} =
             PolicyEngine.check(req(name: "gmail_read", caller: :agent_untrusted, tier: :safe))
  end

  test "operator rules cannot loosen the baseline", %{root: root} do
    # Even with an explicit allow, the baseline gate on a gated command for an
    # untrusted caller still wins (operator rules only run after baseline passes).
    write_policy(root, "- allow gmail_send for agent_untrusted\n")

    assert {:confirm, meta} =
             PolicyEngine.check(req(name: "gmail_send", caller: :agent_untrusted, gated: true))

    assert meta.policy == :baseline
  end

  # --- end-to-end through Commands.call ---------------------------------

  test "an operator deny is enforced at Commands.call and audited", %{root: root} do
    write_policy(root, "- deny event_create for any\n")

    assert {:error, :policy_blocked} =
             Commands.call(
               "event_create",
               %{"event_id" => "e1", "date" => "2026-06-21", "title" => "x"},
               caller: :trusted
             )

    assert Enum.any?(
             Sentinel.list_events(limit: 50),
             &(&1.category == "security_block" and &1.metadata["command"] == "event_create")
           )
  end
end
