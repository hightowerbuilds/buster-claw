defmodule BusterClaw.MemoryTest do
  use BusterClaw.DataCase

  alias BusterClaw.Memory

  test "creates, updates, lists, and deletes memories" do
    now = ~U[2026-05-07 15:00:00Z]

    assert {:ok, memory} =
             Memory.create_memory(%{
               created_at: now,
               text: "Elixir rewrite stays parity-first."
             })

    assert [^memory] = Memory.list_memories()

    assert {:ok, memory} = Memory.update_memory(memory, %{text: "SQLite owns structured state."})
    assert memory.text == "SQLite owns structured state."

    assert {:ok, _} = Memory.delete_memory(memory)
    assert [] = Memory.list_memories()
  end
end
