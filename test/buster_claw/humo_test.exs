defmodule BusterClaw.HumoTest do
  # async: false — Humo pins the fixed conv_id "humo" in the global ChatRegistry.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript
  alias BusterClaw.Humo

  # Minimal scripted spawner (chat_test.exs pattern): emits stream-json lines,
  # then a clean exit, without ever spawning a real claude.
  defp scripting_spawner(lines) do
    fn _prompt, _opts ->
      chat = self()
      port = make_ref()

      spawn(fn ->
        Enum.each(lines, fn map -> send(chat, {port, {:data, Jason.encode!(map) <> "\n"}}) end)
        send(chat, {port, {:exit_status, 0}})
      end)

      {:ok, port}
    end
  end

  test "reserved conv_id creates no Conversations row (homepage tabs stay clean)" do
    assert Humo.conv_id() == "humo"
    refute Enum.any?(Conversations.list(), &(&1.id == "humo"))
  end

  test "send_message drives the shared engine on the humo conversation" do
    spawner =
      scripting_spawner([
        %{"type" => "system", "session_id" => "sess-humo"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "Desde el humo."}]}
        },
        %{"type" => "result", "result" => "ok", "total_cost_usd" => 0.01, "num_turns" => 1}
      ])

    # Pre-register the "humo" chat with the scripted spawner; Humo's facade
    # then finds it via the Registry instead of starting a real one.
    {:ok, _pid} =
      Chat.start_link(conv_id: "humo", spawner: spawner, persist: false, audit: false)

    Humo.subscribe()
    assert :ok = Humo.send_message("hola")

    assert_receive {:agent_chat, "humo", {:message, %{role: :user, text: "hola"}}}
    assert_receive {:agent_chat, "humo", {:status, :running}}
    assert_receive {:agent_chat, "humo", {:message, %{role: :assistant, text: "Desde el humo."}}}
    assert_receive {:agent_chat, "humo", {:status, :idle}}

    assert Humo.status() == :idle
  end

  test "recent returns the persisted humo transcript oldest-first" do
    {:ok, _} = Transcript.record("humo", :user, "primero")
    {:ok, _} = Transcript.record("humo", :assistant, "segundo")

    assert ["primero", "segundo"] = Enum.map(Humo.recent(), & &1.content)
  end
end
