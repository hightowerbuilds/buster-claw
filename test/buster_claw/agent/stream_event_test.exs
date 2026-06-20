defmodule BusterClaw.Agent.StreamEventTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.StreamEvent

  defp tool(name, input \\ %{}),
    do: %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "tool_use", "name" => name, "input" => input}]}
    }

  defp text(t),
    do: %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => t}]}}

  describe "split_lines/1" do
    test "splits complete lines and returns the trailing partial" do
      assert StreamEvent.split_lines("a\nb\nce") == {["a", "b"], "ce"}
    end

    test "no newline yet → everything is the remainder" do
      assert StreamEvent.split_lines("partial") == {[], "partial"}
    end
  end

  describe "decode/1 and parse/1" do
    test "blank / garbage lines are :error" do
      assert StreamEvent.decode("") == :error
      assert StreamEvent.decode("   ") == :error
      assert StreamEvent.decode("not json") == :error
      assert StreamEvent.parse("nope") == :error
    end

    test "parse normalizes a decoded line" do
      assert {:ok, %StreamEvent{kind: :user}} = StreamEvent.parse(~s({"type":"user"}))
    end
  end

  describe "normalize/1" do
    test "system carries the session id" do
      assert %StreamEvent{kind: :system, session_id: "abc"} =
               StreamEvent.normalize(%{"type" => "system", "session_id" => "abc"})
    end

    test "result carries text, cost, turns, session id" do
      ev =
        StreamEvent.normalize(%{
          "type" => "result",
          "result" => "all done",
          "total_cost_usd" => 0.0123,
          "num_turns" => 7,
          "session_id" => "sess-1"
        })

      assert %StreamEvent{
               kind: :result,
               text: "all done",
               cost_usd: 0.0123,
               num_turns: 7,
               session_id: "sess-1"
             } = ev
    end

    test "assistant text turn captures the joined text" do
      assert %StreamEvent{kind: :assistant_text, text: "Let me look."} =
               StreamEvent.normalize(text("Let me look."))
    end

    test "tool_use captures tool, input, and a summary" do
      assert %StreamEvent{kind: :tool_use, tool: "Read", tool_input: %{"file_path" => "x"}} =
               StreamEvent.normalize(tool("Read", %{"file_path" => "x"}))

      assert %StreamEvent{kind: :tool_use, summary: "Bash: ls -la"} =
               StreamEvent.normalize(tool("Bash", %{"command" => "ls -la"}))
    end

    test "unknown events are kept as :unknown" do
      assert %StreamEvent{kind: :unknown} =
               StreamEvent.normalize(%{"type" => "rate_limit_event"})
    end
  end

  describe "activity_state/2" do
    test "system → booting, result → done, user → waiting" do
      assert StreamEvent.activity_state(StreamEvent.normalize(%{"type" => "system"}), :reading) ==
               :booting

      assert StreamEvent.activity_state(StreamEvent.normalize(%{"type" => "result"}), :writing) ==
               :done

      assert StreamEvent.activity_state(StreamEvent.normalize(%{"type" => "user"}), :reading) ==
               :waiting
    end

    test "read-ish tools → reading" do
      for name <- ~w(Read Grep Glob LS NotebookRead WebFetch) do
        assert StreamEvent.activity_state(StreamEvent.normalize(tool(name)), :waiting) == :reading
      end
    end

    test "write-ish tools → writing" do
      for name <- ~w(Write Edit NotebookEdit) do
        assert StreamEvent.activity_state(StreamEvent.normalize(tool(name)), :waiting) == :writing
      end
    end

    test "Bash touching mail → email" do
      cmd = tool("Bash", %{"command" => "./buster-claw mailman poll --once"})
      assert StreamEvent.activity_state(StreamEvent.normalize(cmd), :waiting) == :email
    end

    test "Bash sending / marking done → writing even though it mentions gmail" do
      send_cmd = tool("Bash", %{"command" => "./buster-claw run gmail_send --json '{}'"})
      done_cmd = tool("Bash", %{"command" => "./buster-claw dispatch done 4 --note ok"})
      assert StreamEvent.activity_state(StreamEvent.normalize(send_cmd), :waiting) == :writing
      assert StreamEvent.activity_state(StreamEvent.normalize(done_cmd), :waiting) == :writing
    end

    test "assistant text keeps booting on boot, else waiting" do
      ev = StreamEvent.normalize(text("hi"))
      assert StreamEvent.activity_state(ev, :booting) == :booting
      assert StreamEvent.activity_state(ev, :reading) == :waiting
    end

    test "unknown events keep the previous state" do
      ev = StreamEvent.normalize(%{"type" => "rate_limit_event"})
      assert StreamEvent.activity_state(ev, :email) == :email
    end
  end

  describe "activity_label/1" do
    test "summarizes the current tool" do
      assert StreamEvent.activity_label(StreamEvent.normalize(tool("Read", %{"file_path" => "x"}))) ==
               "Read"

      assert StreamEvent.activity_label(
               StreamEvent.normalize(tool("Bash", %{"command" => "ls -la"}))
             ) =~ "ls -la"
    end

    test "assistant text → thinking, result → its text, unknown → nil" do
      assert StreamEvent.activity_label(StreamEvent.normalize(text("planning"))) == "thinking"

      assert StreamEvent.activity_label(
               StreamEvent.normalize(%{"type" => "result", "result" => "ok"})
             ) == "ok"

      assert StreamEvent.activity_label(StreamEvent.normalize(%{"type" => "x"})) == nil
    end
  end
end
