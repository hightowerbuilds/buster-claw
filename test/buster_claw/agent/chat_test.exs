defmodule BusterClaw.Agent.ChatTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat

  # A spawner that emits a scripted list of stream-json maps (as NDJSON), then a
  # clean exit. Runs inside the Chat process, so `self()` is the GenServer; it
  # echoes the call opts to `parent` so tests can assert on `--resume` threading.
  defp scripting_spawner(parent, scripts_agent) do
    fn prompt, opts ->
      send(parent, {:spawned, prompt, opts})
      chat = self()
      port = make_ref()
      lines = Agent.get_and_update(scripts_agent, fn [h | t] -> {h, t} end)

      spawn(fn ->
        Enum.each(lines, fn map -> send(chat, {port, {:data, Jason.encode!(map) <> "\n"}}) end)
        send(chat, {port, {:exit_status, 0}})
      end)

      {:ok, port}
    end
  end

  # Start a per-conversation chat process registered under a unique conv_id, and
  # subscribe to its topic. Returns the conv_id used to address it.
  defp start_chat(spawner, opts \\ []) do
    conv_id = "test-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)
    {:ok, _pid} = Chat.start_link([conv_id: conv_id, spawner: spawner] ++ opts)
    conv_id
  end

  defp text_event(t),
    do: %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => t}]}}

  defp tool_event(name, input),
    do: %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "tool_use", "name" => name, "input" => input}]}
    }

  test "broadcasts user, assistant, tool, and result events and toggles status" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [
            %{"type" => "system", "session_id" => "sess-1"},
            text_event("On it."),
            tool_event("Bash", %{"command" => "./buster-claw dispatch list"}),
            %{
              "type" => "result",
              "result" => "all done",
              "total_cost_usd" => 0.012,
              "num_turns" => 3
            }
          ]
        ]
      end)

    conv = start_chat(scripting_spawner(self(), scripts))

    assert :ok = Chat.send_message(conv, "work the queue")

    assert_receive {:agent_chat, ^conv, {:message, %{role: :user, text: "work the queue"}}}
    assert_receive {:agent_chat, ^conv, {:status, :running}}
    assert_receive {:agent_chat, ^conv, {:message, %{role: :assistant, text: "On it."}}}
    # First token ends the "thinking" phase and freezes the live timer.
    assert_receive {:agent_chat, ^conv, {:thinking, ms}}
    assert is_integer(ms) and ms >= 0

    assert_receive {:agent_chat, ^conv,
                    {:message, %{role: :tool, text: "Bash: ./buster-claw dispatch list"}}}

    assert_receive {:agent_chat, ^conv, {:message, %{role: :meta, text: meta}}}
    assert meta =~ ~r/^thought [\d.]+s · 3 turns · \$0\.012$/
    assert_receive {:agent_chat, ^conv, {:status, :idle}}
  end

  test "queues a second message while a run is in flight instead of rejecting it" do
    # A spawner that returns a live port but never finishes, so status stays running.
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "first")
    assert :running = Chat.status(conv)

    assert :ok = Chat.send_message(conv, "second")
    assert_receive {:agent_chat, ^conv, {:queue, [%{text: "second"}]}}
    assert [%{text: "second"}] = Chat.queue(conv)
  end

  test "dispatches the queue one turn at a time when each run finishes" do
    # A spawner the test drives: it never finishes on its own, so finishing run one
    # (by sending the exit_status ourselves) deterministically dispatches the queue.
    parent = self()

    spawner = fn prompt, _opts ->
      port = make_ref()
      send(parent, {:spawned, prompt, self(), port})
      {:ok, port}
    end

    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "one")
    assert_receive {:spawned, "one", chat_pid, port1}

    # "two" lands while "one" is mid-flight, so it queues.
    assert :ok = Chat.send_message(conv, "two")
    assert_receive {:agent_chat, ^conv, {:queue, [%{text: "two"}]}}

    # Finishing run one dispatches "two" as its own turn and drains it from the queue.
    send(chat_pid, {port1, {:exit_status, 0}})
    assert_receive {:agent_chat, ^conv, {:queue, []}}
    assert_receive {:spawned, "two", _chat_pid, _port2}
    assert :running = Chat.status(conv)
  end

  test "reorder_queue reorders pending messages by id, front-first" do
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "first")
    assert :ok = Chat.send_message(conv, "a")
    assert :ok = Chat.send_message(conv, "b")
    assert :ok = Chat.send_message(conv, "c")

    assert [%{id: a, text: "a"}, %{id: b, text: "b"}, %{id: c, text: "c"}] = Chat.queue(conv)

    assert :ok = Chat.reorder_queue(conv, [c, a, b])
    assert Enum.map(Chat.queue(conv), & &1.text) == ["c", "a", "b"]
    # An id missing from the list falls to the back, keeping relative order.
    assert :ok = Chat.reorder_queue(conv, [b])
    assert Enum.map(Chat.queue(conv), & &1.text) == ["b", "c", "a"]
  end

  test "interrupt cuts the running turn, marks it interrupted, and settles idle" do
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "go")
    assert :running = Chat.status(conv)

    assert :ok = Chat.interrupt(conv)
    assert_receive {:agent_chat, ^conv, {:message, %{role: :meta, text: "interrupted"}}}
    assert_receive {:agent_chat, ^conv, {:status, :idle}}
    assert :idle = Chat.status(conv)
  end

  test "interrupt on an idle chat is a no-op" do
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    conv = start_chat(spawner)

    assert :ok = Chat.interrupt(conv)
    assert :idle = Chat.status(conv)
  end

  test "interrupt dispatches the next queued message instead of going idle" do
    test_pid = self()

    spawner = fn prompt, _opts ->
      send(test_pid, {:spawned, prompt})
      {:ok, make_ref()}
    end

    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "one")
    assert_receive {:spawned, "one"}
    assert :ok = Chat.send_message(conv, "two")

    # Cutting "one" hands off to the queue, so "two" starts as its own turn.
    assert :ok = Chat.interrupt(conv)
    assert_receive {:spawned, "two"}
    assert :running = Chat.status(conv)
    assert [] = Chat.queue(conv)
  end

  test "barge hard-drops a queued piece to the front and cuts the line" do
    test_pid = self()

    spawner = fn prompt, _opts ->
      send(test_pid, {:spawned, prompt})
      {:ok, make_ref()}
    end

    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "one")
    assert_receive {:spawned, "one"}
    assert :ok = Chat.send_message(conv, "two")
    assert :ok = Chat.send_message(conv, "three")
    assert [%{text: "two"}, %{id: three_id, text: "three"}] = Chat.queue(conv)

    # Hard-drop "three": it jumps the line and runs next; "two" stays queued behind.
    assert :ok = Chat.barge(conv, three_id)
    assert_receive {:spawned, "three"}
    assert :running = Chat.status(conv)
    assert [%{text: "two"}] = Chat.queue(conv)
  end

  test "remove_queued drops a pending message before it is dispatched" do
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "first")
    assert :ok = Chat.send_message(conv, "scratch this")
    assert_receive {:agent_chat, ^conv, {:queue, [%{id: id, text: "scratch this"}]}}

    assert :ok = Chat.remove_queued(conv, id)
    assert_receive {:agent_chat, ^conv, {:queue, []}}
    assert [] = Chat.queue(conv)
  end

  test "captures the session id and resumes on the next message" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [
            %{"type" => "system", "session_id" => "sess-xyz"},
            %{"type" => "result", "result" => "ok"}
          ],
          [%{"type" => "result", "result" => "ok again"}]
        ]
      end)

    conv = start_chat(scripting_spawner(self(), scripts))

    assert :ok = Chat.send_message(conv, "hello")
    assert_receive {:spawned, "hello", first_opts}
    refute "--resume" in Keyword.fetch!(first_opts, :extra_args)
    assert_receive {:agent_chat, ^conv, {:status, :idle}}

    assert :ok = Chat.send_message(conv, "again")
    assert_receive {:spawned, "again", second_opts}
    extra = Keyword.fetch!(second_opts, :extra_args)
    assert "--resume" in extra
    assert "sess-xyz" in extra
  end

  test "extra_cli_args ride every turn, including resumed ones" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [
            %{"type" => "system", "session_id" => "sess-mcp"},
            %{"type" => "result", "result" => "ok"}
          ],
          [%{"type" => "result", "result" => "ok again"}]
        ]
      end)

    mcp_args = ["--strict-mcp-config", "--mcp-config", "/tmp/robinhood.json"]
    conv = start_chat(scripting_spawner(self(), scripts), extra_cli_args: mcp_args)

    assert :ok = Chat.send_message(conv, "list my positions")
    assert_receive {:spawned, "list my positions", first_opts}
    first = Keyword.fetch!(first_opts, :extra_args)
    assert Enum.take(first, -3) == mcp_args
    assert_receive {:agent_chat, ^conv, {:status, :idle}}

    # The flags survive --resume threading on the second turn.
    assert :ok = Chat.send_message(conv, "and my balance")
    assert_receive {:spawned, "and my balance", second_opts}
    second = Keyword.fetch!(second_opts, :extra_args)
    assert "--resume" in second
    assert Enum.take(second, -3) == mcp_args
  end

  test "a hung run is killed and reported as a timeout" do
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    conv = start_chat(spawner, timeout_ms: 30)

    assert :ok = Chat.send_message(conv, "hang")

    assert_receive {:agent_chat, ^conv,
                    {:message, %{role: :error, text: "The run timed out" <> _}}},
                   500

    assert_receive {:agent_chat, ^conv, {:status, :idle}}
    assert :idle = Chat.status(conv)
  end

  test "ignores a timeout whose token doesn't match the current run" do
    spawner = fn _p, _o -> {:ok, make_ref()} end
    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "go")
    assert :running = Chat.status(conv)

    [{pid, _}] = Registry.lookup(BusterClaw.Agent.ChatRegistry, conv)
    # A stale timeout from a prior turn (tokens are positive, so -1 never matches)
    # must not false-kill the fresh in-flight run.
    send(pid, {:run_timeout, -1})

    refute_receive {:agent_chat, ^conv,
                    {:message, %{role: :error, text: "The run timed out" <> _}}},
                   100

    assert :running = Chat.status(conv)
  end

  test "reports an error when the agent cannot be launched" do
    spawner = fn _prompt, _opts -> {:error, :no_agent_cli} end
    conv = start_chat(spawner)

    assert {:error, :no_agent_cli} = Chat.send_message(conv, "go")
    assert_receive {:agent_chat, ^conv, {:message, %{role: :user, text: "go"}}}

    assert_receive {:agent_chat, ^conv,
                    {:message, %{role: :error, text: "No agent CLI found." <> _}}}

    assert :idle = Chat.status(conv)
  end

  test "two conversations run concurrently as separate, isolated processes" do
    # A returns a result and goes idle; B is left running (never finishes).
    finishing = fn _p, _o ->
      chat = self()
      port = make_ref()

      spawn(fn ->
        send(
          chat,
          {port, {:data, Jason.encode!(%{"type" => "result", "result" => "ok"}) <> "\n"}}
        )

        send(chat, {port, {:exit_status, 0}})
      end)

      {:ok, port}
    end

    hanging = fn _p, _o -> {:ok, make_ref()} end

    a = start_chat(finishing)
    b = start_chat(hanging)

    assert :ok = Chat.send_message(a, "alpha")
    assert :ok = Chat.send_message(b, "beta")

    # A completes while B is still running — neither blocks the other.
    assert_receive {:agent_chat, ^a, {:status, :idle}}, 1000
    assert a != b
    assert :idle = Chat.status(a)
    assert :running = Chat.status(b)
  end

  test "reset forgets the session so the next message starts a fresh thread" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [
            %{"type" => "system", "session_id" => "sess-1"},
            text_event("hi"),
            %{"type" => "result", "result" => "ok", "total_cost_usd" => 0.0, "num_turns" => 1}
          ],
          [
            text_event("fresh"),
            %{"type" => "result", "result" => "ok", "total_cost_usd" => 0.0, "num_turns" => 1}
          ]
        ]
      end)

    conv = start_chat(scripting_spawner(self(), scripts))

    assert :ok = Chat.send_message(conv, "first")
    assert_receive {:spawned, "first", opts1}
    refute "--resume" in opts1[:extra_args]
    assert_receive {:agent_chat, ^conv, {:status, :idle}}

    # A normal second turn would resume sess-1; after reset it must not.
    assert :ok = Chat.reset(conv)
    assert_receive {:agent_chat, ^conv, {:reset}}

    assert :ok = Chat.send_message(conv, "second")
    assert_receive {:spawned, "second", opts2}
    refute "--resume" in opts2[:extra_args]
  end

  test "reset kills an in-flight run and drops the queue" do
    hanging = fn _p, _o -> {:ok, make_ref()} end
    conv = start_chat(hanging)

    assert :ok = Chat.send_message(conv, "one")
    assert :running = Chat.status(conv)
    assert :ok = Chat.send_message(conv, "two")
    assert [%{text: "two"}] = Chat.queue(conv)

    assert :ok = Chat.reset(conv)
    assert_receive {:agent_chat, ^conv, {:reset}}
    assert :idle = Chat.status(conv)
    assert [] = Chat.queue(conv)
  end

  # --- the silent-failure trilogy (first-look review Tier 0) ---

  # A spawner that emits RAW (non-stream-json) lines — the shape of Claude's
  # real-world auth/config failures — then exits with `code`.
  defp raw_failing_spawner(parent, raw_lines, code) do
    fn prompt, opts ->
      send(parent, {:spawned, prompt, opts})
      chat = self()
      port = make_ref()

      spawn(fn ->
        Enum.each(raw_lines, fn line -> send(chat, {port, {:data, line <> "\n"}}) end)
        send(chat, {port, {:exit_status, code}})
      end)

      {:ok, port}
    end
  end

  test "a non-zero exit surfaces the CLI's raw output as an error, not silence" do
    spawner =
      raw_failing_spawner(
        self(),
        ["Error: not logged in.", "Run `claude login` to authenticate."],
        1
      )

    conv = start_chat(spawner)
    assert :ok = Chat.send_message(conv, "hello")

    assert_receive {:agent_chat, ^conv, {:message, %{role: :error, text: text}}}
    assert text =~ "exited with status 1"
    assert text =~ "isn't logged in"
    assert text =~ "not logged in."
    assert_receive {:agent_chat, ^conv, {:status, :idle}}
  end

  test "a clean exit after garbage output stays quiet (no error bubble)" do
    spawner = raw_failing_spawner(self(), ["some harmless notice"], 0)
    conv = start_chat(spawner)

    assert :ok = Chat.send_message(conv, "hello")
    assert_receive {:agent_chat, ^conv, {:status, :idle}}
    refute_received {:agent_chat, ^conv, {:message, %{role: :error}}}
  end

  test "an error result renders its text instead of discarding it" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [
            %{"type" => "system", "session_id" => "sess-err"},
            %{
              "type" => "result",
              "subtype" => "error_during_execution",
              "is_error" => true,
              "result" => "Invalid API key. Please run claude login.",
              "num_turns" => 1
            }
          ]
        ]
      end)

    conv = start_chat(scripting_spawner(self(), scripts))
    assert :ok = Chat.send_message(conv, "hello")

    assert_receive {:agent_chat, ^conv,
                    {:message, %{role: :error, text: "Invalid API key. Please run claude login."}}}
  end

  test "an error result with no body still says something" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [[%{"type" => "result", "subtype" => "error_max_turns", "num_turns" => 50}]]
      end)

    conv = start_chat(scripting_spawner(self(), scripts))
    assert :ok = Chat.send_message(conv, "hello")

    assert_receive {:agent_chat, ^conv, {:message, %{role: :error, text: text}}}
    assert text =~ "error_max_turns"
  end
end
