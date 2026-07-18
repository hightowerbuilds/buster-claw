defmodule BusterClaw.Browser.ChecksTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Browser.Checks

  @steps [
    %{"action" => "navigate", "url" => "https://example.com"},
    %{"action" => "assert", "kind" => "title_contains", "value" => "Example"}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "bc_checks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:buster_claw, :workspace_root)
      else
        Application.put_env(:buster_claw, :workspace_root, previous)
      end

      File.rm_rf(root)
    end)

    :ok
  end

  test "save → list → load round-trips the definition" do
    assert {:ok, %{name: "login-check", steps: 2}} =
             Checks.save("login-check", @steps, "The login smoke check")

    assert [%{name: "login-check", description: "The login smoke check", steps: 2, last_run: nil}] =
             Checks.list()

    assert {:ok, %{steps: @steps, description: "The login smoke check"}} =
             Checks.load("login-check")
  end

  test "bad names and bad flows are refused at save time" do
    assert {:error, :invalid_check_name} = Checks.save("../evil", @steps)
    assert {:error, :invalid_check_name} = Checks.save("Not A Slug", @steps)
    assert {:error, :invalid_check_name} = Checks.save(nil, @steps)
    assert {:error, :empty_flow} = Checks.save("ok-name", [])
    assert {:error, {:bad_step, 1, :missing_action}} = Checks.save("ok-name", [%{}])

    assert {:error, {:bad_step, 1, {:unknown_action, "teleport"}}} =
             Checks.save("ok-name", [%{"action" => "teleport"}])

    assert Checks.list() == []
    assert {:error, :check_not_found} = Checks.load("never-saved")
  end

  test "record_run appends history and re-save preserves it" do
    {:ok, _saved} = Checks.save("check-a", @steps)

    passed = %{status: "passed", steps: [%{}, %{}], failed_step: nil}
    assert :ok = Checks.record_run("check-a", passed, 812)

    failed = %{
      status: "failed",
      failed_step: 1,
      steps: [
        %{action: "click", status: "failed", detail: %{error: "no element matched"}}
      ]
    }

    assert :ok = Checks.record_run("check-a", failed, 90)

    assert [%{last_run: last}] = Checks.list()
    assert last =~ "FAILED at step 1 (click)"
    assert last =~ "no element matched"

    {:ok, _resaved} = Checks.save("check-a", @steps, "updated wording")
    assert [%{description: "updated wording", last_run: still}] = Checks.list()
    assert still =~ "FAILED at step 1 (click)"
  end

  test "recording a run for a missing check is a logged error, not a raise" do
    report = %{status: "passed", steps: [], failed_step: nil}
    assert {:error, :check_not_found} = Checks.record_run("ghost", report, 5)
  end
end
