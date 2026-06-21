defmodule BusterClaw.Agent.ChatPersistenceTest do
  # async: false — a Chat GenServer (a separate process) writes to the DB, so we
  # share the sandbox connection rather than allowing a specific pid.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.{Chat, Transcript}
  alias BusterClaw.Sentinel

  defp emit_spawner(scripts_agent) do
    fn _prompt, _opts ->
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

  test "a completed run is recorded on the Sentinel audit feed" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [[%{"type" => "result", "result" => "ok", "total_cost_usd" => 0.02, "num_turns" => 4}]]
      end)

    conv_id = "audit-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, _pid} =
      Chat.start_link(
        conv_id: conv_id,
        spawner: emit_spawner(scripts),
        persist: false,
        audit: true
      )

    assert :ok = Chat.send_message(conv_id, "do it")
    assert_receive {:agent_chat, ^conv_id, {:status, :idle}}, 1000

    events = Sentinel.list_events()
    run = Enum.find(events, &(&1.message == "Chat agent run completed"))
    assert run, "expected a 'Chat agent run completed' audit event"
    assert run.category == "command_invoke"
    assert run.metadata["source"] == "chat"
    assert run.metadata["num_turns"] == 4
  end

  test "a run's transcript is persisted as display-ready messages" do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          [
            %{"type" => "system", "session_id" => "sess-9"},
            %{
              "type" => "assistant",
              "message" => %{"content" => [%{"type" => "text", "text" => "Working."}]}
            },
            %{"type" => "result", "result" => "ok", "total_cost_usd" => 0.02, "num_turns" => 4}
          ]
        ]
      end)

    spawner = fn _prompt, _opts ->
      chat = self()
      port = make_ref()
      lines = Agent.get_and_update(scripts, fn [h | t] -> {h, t} end)

      spawn(fn ->
        Enum.each(lines, fn map -> send(chat, {port, {:data, Jason.encode!(map) <> "\n"}}) end)
        send(chat, {port, {:exit_status, 0}})
      end)

      {:ok, port}
    end

    conv_id = "persist-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)
    {:ok, _pid} = Chat.start_link(conv_id: conv_id, spawner: spawner, persist: true)

    assert :ok = Chat.send_message(conv_id, "do it")
    assert_receive {:agent_chat, ^conv_id, {:status, :idle}}, 1000

    rows = Transcript.recent(conv_id)
    assert Enum.map(rows, &{&1.role, &1.content}) == [
             {"user", "do it"},
             {"assistant", "Working."},
             {"meta", "4 turns · $0.02"}
           ]

    # The session id captured mid-run is stamped on subsequently-written rows.
    assert Enum.any?(rows, &(&1.session_id == "sess-9"))
  end
end
