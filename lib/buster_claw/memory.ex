defmodule BusterClaw.Memory do
  @moduledoc "Persistent memory records for prompt context."

  alias BusterClaw.Memory.Memory
  alias BusterClaw.Repo

  def list_memories, do: Repo.all(Memory)
  def get_memory!(id), do: Repo.get!(Memory, id)
  def create_memory(attrs), do: %Memory{} |> Memory.changeset(attrs) |> Repo.insert()

  def update_memory(%Memory{} = memory, attrs),
    do: memory |> Memory.changeset(attrs) |> Repo.update()

  def delete_memory(%Memory{} = memory), do: Repo.delete(memory)
end
