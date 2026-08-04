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
      assert StreamEvent.activity_label(
               StreamEvent.normalize(tool("Read", %{"file_path" => "x"}))
             ) ==
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

  # Every line below is a VERBATIM event captured from the real CLI on 08-03
  # (codex-cli 0.146.0, opencode 1.18.3) — see AGENT_BACKEND_ROADMAP.md. The
  # point of pasting real output rather than hand-writing plausible JSON is that
  # a parser written against imagined events is exactly the failure this
  # codebase keeps hitting.
  describe "codex — exec --json" do
    test "thread.started carries the session id for resume" do
      line = ~s({"type":"thread.started","thread_id":"019fca22-df8d-7bb3-bb48-1fae2ab72aa7"})
      assert {:ok, event} = StreamEvent.parse(:codex, line)
      assert event.kind == :system
      assert event.session_id == "019fca22-df8d-7bb3-bb48-1fae2ab72aa7"
    end

    test "an agent_message is assistant text" do
      line =
        ~s({"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I will inspect the directory now."}})

      assert {:ok, event} = StreamEvent.parse(:codex, line)
      assert event.kind == :assistant_text
      assert event.text == "I will inspect the directory now."
    end

    test "a started command_execution is a tool_use carrying the command" do
      line =
        ~s({"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"ls -la","aggregated_output":"","exit_code":null,"status":"in_progress"}})

      assert {:ok, event} = StreamEvent.parse(:codex, line)
      assert event.kind == :tool_use
      assert event.tool == "command_execution"
      assert event.tool_input == %{"command" => "ls -la"}
      assert StreamEvent.activity_label(event) == "$ ls -la"
    end

    test "a completed command_execution is a tool_result, not a second tool_use" do
      line =
        ~s({"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"ls","aggregated_output":"a.txt","exit_code":0,"status":"completed"}})

      assert {:ok, %{kind: :tool_result}} = StreamEvent.parse(:codex, line)
    end

    test "turn.completed ends the run" do
      line =
        ~s({"type":"turn.completed","usage":{"input_tokens":29205,"cached_input_tokens":22016,"output_tokens":128}})

      assert {:ok, event} = StreamEvent.parse(:codex, line)
      assert event.kind == :result
      # Codex reports tokens but no dollar figure, and this app does not own a
      # price table — inventing one would be a number the operator trusts.
      assert event.cost_usd == nil
      assert event.raw["usage"]["output_tokens"] == 128
    end

    test "an unobserved event is :unknown with raw intact, never a guess" do
      assert {:ok, event} = StreamEvent.parse(:codex, ~s({"type":"turn.started"}))
      assert event.kind == :unknown
      assert event.raw == %{"type" => "turn.started"}
    end
  end

  describe "opencode — run --format json" do
    test "step_start carries the session id" do
      line =
        ~s({"type":"step_start","timestamp":1785802734039,"sessionID":"ses_035dcd","part":{"type":"step-start"}})

      assert {:ok, event} = StreamEvent.parse(:opencode, line)
      assert event.kind == :system
      assert event.session_id == "ses_035dcd"
    end

    test "text is assistant text, nested under part" do
      line =
        ~s({"type":"text","sessionID":"ses_1","part":{"type":"text","text":"DONE","time":{"start":1,"end":2}}})

      assert {:ok, event} = StreamEvent.parse(:opencode, line)
      assert event.kind == :assistant_text
      assert event.text == "DONE"
    end

    test "an in-flight tool is a tool_use; a completed one is a tool_result" do
      running =
        ~s({"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"read","state":{"status":"running","input":{"filePath":"/tmp/a.txt"}}}})

      done =
        ~s({"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"/tmp/a.txt"}}}})

      assert {:ok, %{kind: :tool_use, tool: "read"}} = StreamEvent.parse(:opencode, running)
      assert {:ok, %{kind: :tool_result, tool: "read"}} = StreamEvent.parse(:opencode, done)
    end

    # step_finish fires once per STEP. Treating "tool-calls" as the end would
    # close the transcript on the first tool the model used.
    test "only reason: stop is the end of the run" do
      mid =
        ~s({"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"tool-calls","tokens":{"total":1},"cost":0}})

      final =
        ~s({"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","tokens":{"total":8050},"cost":0.0021}})

      assert {:ok, %{kind: :unknown}} = StreamEvent.parse(:opencode, mid)
      assert {:ok, event} = StreamEvent.parse(:opencode, final)
      assert event.kind == :result
      # The only harness of the three that tells us what a run actually cost.
      assert event.cost_usd == 0.0021
    end

    test "lower-cased tool names still classify for the activity display" do
      read =
        ~s({"type":"tool_use","sessionID":"s","part":{"type":"tool","tool":"read","state":{"status":"running","input":{}}}})

      write =
        ~s({"type":"tool_use","sessionID":"s","part":{"type":"tool","tool":"write","state":{"status":"running","input":{}}}})

      {:ok, r} = StreamEvent.parse(:opencode, read)
      {:ok, w} = StreamEvent.parse(:opencode, write)

      assert StreamEvent.activity_state(r, :waiting) == :reading
      assert StreamEvent.activity_state(w, :waiting) == :writing
    end
  end

  describe "backend dispatch" do
    # Every caller predates harness selection and was written against claude.
    test "nil and unknown backends are read as claude" do
      line = ~s({"type":"system","session_id":"abc"})

      assert {:ok, %{kind: :system, session_id: "abc"}} = StreamEvent.parse(nil, line)
      assert {:ok, %{kind: :system, session_id: "abc"}} = StreamEvent.parse(:gemini, line)
      assert {:ok, %{kind: :system, session_id: "abc"}} = StreamEvent.parse(line)
    end

    # A claude event fed to the codex parser must not be silently reinterpreted.
    test "a schema from the wrong harness is :unknown, not a misreading" do
      assert {:ok, %{kind: :unknown}} =
               StreamEvent.parse(:codex, ~s({"type":"system","session_id":"abc"}))
    end
  end

  # Three shapes, one normalized map. Every line pasted below is real output
  # captured 08-03 — the claude figures come from an actual one-word run.
  describe "usage, normalized across harnesses" do
    test "claude reports tokens AND dollars" do
      line =
        ~s({"type":"result","result":"OK","session_id":"s","num_turns":1,) <>
          ~s("total_cost_usd":0.0802325,"usage":{"input_tokens":2,) <>
          ~s("cache_creation_input_tokens":7191,"cache_read_input_tokens":15273,"output_tokens":4}})

      assert {:ok, event} = StreamEvent.parse(:claude, line)

      assert event.usage == %{
               input_tokens: 2,
               output_tokens: 4,
               cache_read_tokens: 15_273,
               cache_write_tokens: 7191,
               cost_usd: 0.0802325
             }
    end

    # The claim "the CLI does not report spend back to us" lived in two roadmaps,
    # the tutorial and the summary until 08-03. It was never true of claude, and
    # this is the assertion that stops it coming back.
    test "claude's cost is a real number, not nil" do
      line = ~s({"type":"result","result":"OK","total_cost_usd":0.0802325,"usage":{"input_tokens":2}})
      assert {:ok, %{cost_usd: cost}} = StreamEvent.parse(:claude, line)
      assert is_number(cost) and cost > 0
    end

    test "codex reports tokens, and its cost stays nil rather than invented" do
      line =
        ~s({"type":"turn.completed","usage":{"input_tokens":29205,"cached_input_tokens":22016,) <>
          ~s("cache_write_input_tokens":0,"output_tokens":128,"reasoning_output_tokens":0}})

      assert {:ok, event} = StreamEvent.parse(:codex, line)
      assert event.usage.input_tokens == 29_205
      assert event.usage.output_tokens == 128
      assert event.usage.cache_read_tokens == 22_016

      # Deriving dollars from tokens needs a price table this app does not own.
      # A number the operator reads as "what this cost" must come from the CLI
      # that billed it, or not appear at all.
      assert event.usage.cost_usd == nil
    end

    test "opencode reports both, nested differently" do
      line =
        ~s({"type":"step_finish","sessionID":"s","part":{"type":"step-finish","reason":"stop",) <>
          ~s("tokens":{"total":8050,"input":8048,"output":2,"cache":{"write":0,"read":0}},"cost":0.0021}})

      assert {:ok, event} = StreamEvent.parse(:opencode, line)
      assert event.usage.input_tokens == 8048
      assert event.usage.output_tokens == 2
      assert event.usage.cost_usd == 0.0021
    end

    # A missing count must read as "not stated", never as zero — the difference
    # between "this run used no cache" and "we don't know".
    test "an absent field is nil, not zero" do
      assert {:ok, event} =
               StreamEvent.parse(:claude, ~s({"type":"result","usage":{"input_tokens":5}}))

      assert event.usage.input_tokens == 5
      assert event.usage.output_tokens == nil
      assert event.usage.cache_read_tokens == nil
    end

    test "a result with no usage block at all is nil, not an empty map" do
      assert {:ok, %{usage: nil}} = StreamEvent.parse(:claude, ~s({"type":"result","result":"OK"}))
      assert {:ok, %{usage: nil}} = StreamEvent.parse(:codex, ~s({"type":"turn.completed"}))
    end
  end

  describe "run_usage/2 — for the blocking surfaces" do
    test "finds the result event in a whole captured stream" do
      output =
        Enum.join(
          [
            ~s({"type":"system","session_id":"s"}),
            ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}),
            ~s({"type":"result","result":"OK","total_cost_usd":0.5,"usage":{"input_tokens":9,"output_tokens":3}})
          ],
          "\n"
        )

      assert %{input_tokens: 9, output_tokens: 3, cost_usd: 0.5} = StreamEvent.run_usage(:claude, output)
    end

    # opencode emits one step_finish per STEP; only the last ends the run, so the
    # last result event is the one that carries the run's totals.
    test "takes the LAST result, which is the one that ends an opencode run" do
      output =
        Enum.join(
          [
            ~s({"type":"step_finish","part":{"reason":"tool-calls","tokens":{"input":1,"output":1},"cost":0.001}}),
            ~s({"type":"step_finish","part":{"reason":"stop","tokens":{"input":80,"output":9},"cost":0.02}})
          ],
          "\n"
        )

      assert %{input_tokens: 80, cost_usd: 0.02} = StreamEvent.run_usage(:opencode, output)
    end

    test "is nil for output that never finished, and for junk" do
      assert StreamEvent.run_usage(:claude, ~s({"type":"system","session_id":"s"})) == nil
      assert StreamEvent.run_usage(:claude, "not json at all") == nil
      assert StreamEvent.run_usage(:claude, nil) == nil
    end
  end

end
