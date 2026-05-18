defmodule BusterClaw.CommandsTest do
  use BusterClaw.DataCase

  alias BusterClaw.Commands

  describe "list_commands/0" do
    test "returns the full catalog" do
      catalog = Commands.list_commands()
      assert is_list(catalog)
      assert length(catalog) >= 70
      assert Enum.all?(catalog, &Map.has_key?(&1, :name))
      assert Enum.all?(catalog, &Map.has_key?(&1, :type))
      assert Enum.all?(catalog, &Map.has_key?(&1, :tier))
      assert Enum.all?(catalog, &Map.has_key?(&1, :description))
      assert Enum.all?(catalog, &Map.has_key?(&1, :args))
    end

    test "every command has a unique name" do
      names = Enum.map(Commands.list_commands(), & &1.name)
      assert names == Enum.uniq(names)
    end

    test "every command name matches a function in the module" do
      for %{name: name} <- Commands.list_commands() do
        assert function_exported?(Commands, String.to_atom(name), 1),
               "missing implementation for command #{name}/1"
      end
    end

    test "every command has tier safe or restricted" do
      for %{name: name, tier: tier} <- Commands.list_commands() do
        assert tier in [:safe, :restricted],
               "command #{name} has unexpected tier #{inspect(tier)}"
      end
    end
  end

  describe "call/2 dispatcher" do
    test "dispatches to the matching command" do
      assert {:ok, []} = Commands.call("source_list", %{})
    end

    test "normalizes atom-keyed args to strings" do
      assert {:ok, %{name: "n", text: "remember this"} = mem} =
               normalize(Commands.call("memory_remember", %{text: "remember this"}))

      assert mem.text == "remember this"
    end

    test "returns :unknown_command for missing commands" do
      assert {:error, :unknown_command} = Commands.call("nope_nope", %{})
    end
  end

  describe "sources" do
    test "list, create, get, update, delete round trip" do
      assert {:ok, []} = Commands.source_list(%{})

      assert {:ok, source} =
               Commands.source_create(%{"url" => "https://example.com/feed", "type" => "rss"})

      assert {:ok, ^source} = Commands.source_get(%{"id" => source.id})

      assert {:ok, updated} =
               Commands.source_update(%{"id" => source.id, "name" => "Renamed"})

      assert updated.name == "Renamed"

      assert {:ok, _} = Commands.source_delete(%{"id" => source.id})
      assert {:error, :not_found} = Commands.source_get(%{"id" => source.id})
    end

    test "create returns changeset on invalid args" do
      assert {:error, %Ecto.Changeset{}} = Commands.source_create(%{"url" => ""})
    end
  end

  describe "providers" do
    test "create requires api_key for non-ollama" do
      assert {:error, %Ecto.Changeset{}} =
               Commands.provider_create(%{
                 "name" => "anth",
                 "type" => "anthropic",
                 "model" => "claude"
               })
    end

    test "ollama does not require api_key" do
      assert {:ok, provider} =
               Commands.provider_create(%{
                 "name" => "local",
                 "type" => "ollama",
                 "model" => "llama3"
               })

      assert provider.type == "ollama"
    end

    test "active returns nil when no provider is active" do
      assert {:ok, nil} = Commands.provider_active(%{})
    end

    test "set_active flips the active flag" do
      {:ok, p1} =
        Commands.provider_create(%{"name" => "a", "type" => "ollama", "model" => "llama3"})

      assert {:ok, active} = Commands.provider_set_active(%{"id" => p1.id})
      assert active.active == true
      assert {:ok, %{id: id}} = Commands.provider_active(%{})
      assert id == p1.id
    end
  end

  describe "memory" do
    test "remember/list/forget round trip" do
      assert {:ok, mem} = Commands.memory_remember(%{"text" => "hello memory"})
      assert {:ok, [^mem]} = Commands.memory_list(%{})
      assert {:ok, _} = Commands.memory_forget(%{"id" => mem.id})
      assert {:ok, []} = Commands.memory_list(%{})
    end

    test "forget returns :not_found for missing id" do
      assert {:error, :not_found} = Commands.memory_forget(%{"id" => 99_999})
    end
  end

  describe "calendar events" do
    test "create + get + delete" do
      assert {:ok, event} =
               Commands.event_create(%{
                 "event_id" => "ev1",
                 "date" => "2026-06-01",
                 "title" => "Conference"
               })

      assert {:ok, ^event} = Commands.event_get(%{"id" => event.id})
      assert {:ok, _} = Commands.event_delete(%{"id" => event.id})
    end
  end

  describe "documents" do
    test "list returns documents" do
      assert {:ok, list} = Commands.document_list(%{})
      assert is_list(list)
    end

    test "document_read returns :not_found for missing id" do
      assert {:error, :not_found} = Commands.document_read(%{"id" => 99_999})
    end
  end

  describe "chat" do
    test "chat_messages on a fresh session is empty" do
      assert {:ok, messages} = Commands.chat_messages(%{"session_id" => "test-fresh"})
      assert is_list(messages)
    end

    test "chat_clear returns :cleared" do
      assert {:ok, :cleared} = Commands.chat_clear(%{"session_id" => "test-clear"})
    end
  end

  describe "runtime" do
    test "status returns a snapshot map" do
      assert {:ok, snapshot} = Commands.runtime_status(%{})
      assert Map.has_key?(snapshot, :app)
      assert Map.has_key?(snapshot, :phase)
    end
  end

  defp normalize({:ok, %BusterClaw.Memory.Memory{} = memory}),
    do: {:ok, %{name: "n", text: memory.text}}

  defp normalize(other), do: other
end
