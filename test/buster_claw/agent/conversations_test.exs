defmodule BusterClaw.Agent.ConversationsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Agent.Conversations

  test "list seeds the default conversation on a virgin table" do
    assert [conv] = Conversations.list()
    assert conv.id == Conversations.default_id()
    # Idempotent: a second call doesn't add another row.
    assert [^conv] = Conversations.list()
  end

  test "create adds a conversation with a generated id and default title" do
    # Seed the default first (as the LiveView does on mount), then add a chat.
    assert [%{id: "default"}] = Conversations.list()

    {:ok, conv} = Conversations.create()
    assert conv.title == Conversations.default_title()
    assert String.starts_with?(conv.id, "conv-")

    ids = Conversations.list() |> Enum.map(& &1.id)
    assert "default" in ids and conv.id in ids
    # Order is stable across calls (tabs don't reshuffle between renders).
    assert ids == (Conversations.list() |> Enum.map(& &1.id))
  end

  test "rename changes the title" do
    {:ok, conv} = Conversations.create()
    assert {:ok, renamed} = Conversations.rename(conv.id, "Research GWS")
    assert renamed.title == "Research GWS"
    assert Conversations.get(conv.id).title == "Research GWS"
  end

  test "close archives the conversation and drops it from the open list" do
    {:ok, conv} = Conversations.create()
    assert :ok = Conversations.close(conv.id)

    refute conv.id in (Conversations.list() |> Enum.map(& &1.id))
    # Still queryable (transcript preserved), just archived.
    assert Conversations.get(conv.id).archived_at != nil
  end

  test "touch bumps updated_at without error" do
    {:ok, conv} = Conversations.create()
    assert :ok = Conversations.touch(conv.id)
    assert :ok = Conversations.touch("nonexistent")
  end
end
