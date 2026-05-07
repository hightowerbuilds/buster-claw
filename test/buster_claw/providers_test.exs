defmodule BusterClaw.ProvidersTest do
  use BusterClaw.DataCase

  alias BusterClaw.Providers

  test "creates, updates, lists, and deletes providers" do
    assert {:ok, provider} =
             Providers.create_provider(%{
               name: "openrouter-main",
               type: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               api_key: "secret",
               model: "openai/gpt-5.4",
               active: true
             })

    assert [^provider] = Providers.list_providers()

    assert {:ok, provider} = Providers.update_provider(provider, %{active: false})
    refute provider.active

    assert {:ok, _} = Providers.delete_provider(provider)
    assert [] = Providers.list_providers()
  end

  test "validates provider type and unique name" do
    assert {:error, changeset} =
             Providers.create_provider(%{name: "bad", type: "bad", model: "x"})

    assert %{type: [_]} = errors_on(changeset)

    assert {:ok, _} =
             Providers.create_provider(%{name: "ollama", type: "ollama", model: "llama3"})

    assert {:error, changeset} =
             Providers.create_provider(%{name: "ollama", type: "ollama", model: "llama3"})

    assert %{name: [_]} = errors_on(changeset)
  end
end
