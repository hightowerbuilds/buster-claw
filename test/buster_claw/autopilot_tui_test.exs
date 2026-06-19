defmodule BusterClaw.Autopilot.TuiTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Autopilot.Tui

  defp tool(name, input \\ %{}),
    do: %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "tool_use", "name" => name, "input" => input}]}
    }

  describe "classify/2" do
    test "system init → booting, result → done, tool_result → waiting" do
      assert Tui.classify(%{"type" => "system", "subtype" => "init"}, :reading) == :booting
      assert Tui.classify(%{"type" => "result", "subtype" => "success"}, :writing) == :done
      assert Tui.classify(%{"type" => "user"}, :reading) == :waiting
    end

    test "read-ish tools → reading" do
      for name <- ~w(Read Grep Glob LS NotebookRead WebFetch) do
        assert Tui.classify(tool(name), :waiting) == :reading
      end
    end

    test "write-ish tools → writing" do
      for name <- ~w(Write Edit NotebookEdit) do
        assert Tui.classify(tool(name), :waiting) == :writing
      end
    end

    test "Bash touching mail → email" do
      assert Tui.classify(
               tool("Bash", %{"command" => "./buster-claw mailman poll --once"}),
               :waiting
             ) == :email

      assert Tui.classify(
               tool("Bash", %{"command" => "./buster-claw dispatch claim --job mail-triage"}),
               :waiting
             ) == :email
    end

    test "Bash sending / marking done → writing (even though it mentions gmail)" do
      assert Tui.classify(
               tool("Bash", %{"command" => "./buster-claw run gmail_send --json '{}'"}),
               :waiting
             ) == :writing

      assert Tui.classify(
               tool("Bash", %{"command" => "./buster-claw dispatch done 4 --note ok"}),
               :waiting
             ) == :writing
    end

    test "an assistant text turn keeps booting on boot, else waiting" do
      text = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "Let me look."}]}
      }

      assert Tui.classify(text, :booting) == :booting
      assert Tui.classify(text, :reading) == :waiting
    end

    test "unknown events keep the previous state" do
      assert Tui.classify(%{"type" => "rate_limit_event"}, :email) == :email
    end
  end

  describe "activity/1" do
    test "summarizes the current tool" do
      assert Tui.activity(tool("Read", %{"file_path" => "x"})) == "Read"
      assert Tui.activity(tool("Bash", %{"command" => "ls -la"})) =~ "ls -la"
    end
  end
end
