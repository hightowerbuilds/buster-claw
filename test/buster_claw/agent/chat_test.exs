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

  defp start_chat(spawner, opts \\ []) do
    conv_id = "test-#{System.unique_integer([:positive])}"
    name = :"chat_#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, pid} =
      Chat.start_link([conv_id: conv_id, name: name, spawner: spawner] ++ opts)

    {pid, conv_id}
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

    {pid, _conv} = start_chat(scripting_spawner(self(), scripts))

    assert :ok = Chat.send_message(pid, "work the queue")

    assert_receive {:agent_chat, {:message, %{role: :user, text: "work the queue"}}}
    assert_receive {:agent_chat, {:status, :running}}
    assert_receive {:agent_chat, {:message, %{role: :assistant, text: "On it."}}}
    assert_receive {:agent_chat,
                    {:message, %{role: :tool, text: "Bash: ./buster-claw dispatch list"}}}

    assert_receive {:agent_chat, {:message, %{role: :meta, text: "3 turns · $0.012"}}}
    assert_receive {:agent_chat, {:status, :idle}}
  end

  test "rejects a second message while a run is in flight" do
    # A spawner that returns a live port but never finishes, so status stays running.
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    {pid, _conv} = start_chat(spawner)

    assert :ok = Chat.send_message(pid, "first")
    assert :running = Chat.status(pid)
    assert {:error, :busy} = Chat.send_message(pid, "second")
  end

  test "captures the session id and resumes on the next message" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [%{"type" => "system", "session_id" => "sess-xyz"}, %{"type" => "result", "result" => "ok"}],
          [%{"type" => "result", "result" => "ok again"}]
        ]
      end)

    {pid, _conv} = start_chat(scripting_spawner(self(), scripts))

    assert :ok = Chat.send_message(pid, "hello")
    assert_receive {:spawned, "hello", first_opts}
    refute "--resume" in Keyword.fetch!(first_opts, :extra_args)
    assert_receive {:agent_chat, {:status, :idle}}

    assert :ok = Chat.send_message(pid, "again")
    assert_receive {:spawned, "again", second_opts}
    extra = Keyword.fetch!(second_opts, :extra_args)
    assert "--resume" in extra
    assert "sess-xyz" in extra
  end

  test "a hung run is killed and reported as a timeout" do
    spawner = fn _prompt, _opts -> {:ok, make_ref()} end
    {pid, _conv} = start_chat(spawner, timeout_ms: 30)

    assert :ok = Chat.send_message(pid, "hang")
    assert_receive {:agent_chat, {:message, %{role: :error, text: "The run timed out" <> _}}}, 500
    assert_receive {:agent_chat, {:status, :idle}}
    assert :idle = Chat.status(pid)
  end

  test "reports an error when the agent cannot be launched" do
    spawner = fn _prompt, _opts -> {:error, :no_agent_cli} end
    {pid, _conv} = start_chat(spawner)

    assert {:error, :no_agent_cli} = Chat.send_message(pid, "go")
    assert_receive {:agent_chat, {:message, %{role: :user, text: "go"}}}

    assert_receive {:agent_chat,
                    {:message, %{role: :error, text: "No agent CLI found." <> _}}}

    assert :idle = Chat.status(pid)
  end
end
