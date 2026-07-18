defmodule BusterClaw.Browser.FlowRunnerTest do
  # Pure: exec and screenshot are injected, no Bridge/DB/Sentinel touched.
  use ExUnit.Case, async: true

  alias BusterClaw.Browser.FlowRunner

  defp exec_recording(test_pid, results \\ %{}) do
    fn action, args ->
      send(test_pid, {:exec, action, args})
      Map.get(results, action, {:ok, %{done: action}})
    end
  end

  defp no_shot, do: fn -> nil end

  test "runs every step in order and reports passed" do
    steps = [
      %{"action" => "navigate", "url" => "https://example.com"},
      %{"action" => "wait", "until" => "navigation"},
      %{"action" => "extract"}
    ]

    assert {:ok, report} =
             FlowRunner.run(steps, exec: exec_recording(self()), screenshot: no_shot())

    assert %{status: "passed", failed_step: nil} = report
    refute Map.has_key?(report, :screenshot)
    assert [%{step: 1, action: "navigate"}, %{step: 2}, %{step: 3}] = report.steps
    assert Enum.all?(report.steps, &(&1.status == "passed" and is_integer(&1.ms)))

    assert_received {:exec, "navigate", %{"url" => "https://example.com"}}
    assert_received {:exec, "wait", %{"until" => "navigation"}}
    assert_received {:exec, "extract", %{}}
  end

  test "halts at the first failing step and attaches the screenshot" do
    steps = [
      %{"action" => "navigate", "url" => "https://example.com"},
      %{"action" => "click", "selector" => "#gone"},
      %{"action" => "extract"}
    ]

    exec =
      exec_recording(self(), %{"click" => {:error, {:element_action_failed, "no match"}}})

    assert {:ok, report} =
             FlowRunner.run(steps, exec: exec, screenshot: fn -> %{path: "/tmp/fail.png"} end)

    assert %{status: "failed", failed_step: 2, screenshot: %{path: "/tmp/fail.png"}} = report
    assert [%{status: "passed"}, %{status: "failed", detail: %{error: error}}] = report.steps
    assert error =~ "element_action_failed"
    refute_received {:exec, "extract", _args}
  end

  test "a wait that never matched fails the flow" do
    steps = [%{"action" => "wait", "until" => "text", "value" => "Done"}]
    exec = exec_recording(self(), %{"wait" => {:ok, %{matched: false, waited_ms: 500}}})

    assert {:ok, %{status: "failed", failed_step: 1}} =
             FlowRunner.run(steps, exec: exec, screenshot: no_shot())
  end

  test "assert passed: false fails the flow; passed: true does not" do
    steps = [%{"action" => "assert", "kind" => "text", "value" => "Welcome"}]

    passing = exec_recording(self(), %{"assert" => {:ok, %{passed: true, kind: "text"}}})
    failing = exec_recording(self(), %{"assert" => {:ok, %{passed: false, kind: "text"}}})

    assert {:ok, %{status: "passed"}} =
             FlowRunner.run(steps, exec: passing, screenshot: no_shot())

    assert {:ok, %{status: "failed", failed_step: 1}} =
             FlowRunner.run(steps, exec: failing, screenshot: no_shot())
  end

  test "oversized extract text is capped with a truncation flag" do
    big = String.duplicate("a", 30_000)
    exec = exec_recording(self(), %{"extract" => {:ok, %{url: "u", text: big}}})

    assert {:ok, %{steps: [%{detail: detail}]}} =
             FlowRunner.run([%{"action" => "extract"}], exec: exec, screenshot: no_shot())

    assert detail.text_truncated
    assert byte_size(detail.text) == 20_000
  end

  test "invalid flows are rejected before any step runs" do
    exec = exec_recording(self())

    assert {:error, :steps_must_be_a_list} = FlowRunner.run("nope", exec: exec)
    assert {:error, :empty_flow} = FlowRunner.run([], exec: exec)

    too_many = List.duplicate(%{"action" => "extract"}, 26)
    assert {:error, {:too_many_steps, 26}} = FlowRunner.run(too_many, exec: exec)

    assert {:error, {:bad_step, 2, {:unknown_action, "teleport"}}} =
             FlowRunner.run(
               [%{"action" => "extract"}, %{"action" => "teleport"}],
               exec: exec
             )

    assert {:error, {:bad_step, 1, :missing_action}} = FlowRunner.run([%{}], exec: exec)
    assert {:error, {:bad_step, 1, :not_a_map}} = FlowRunner.run(["extract"], exec: exec)

    refute_received {:exec, _action, _args}
  end
end
