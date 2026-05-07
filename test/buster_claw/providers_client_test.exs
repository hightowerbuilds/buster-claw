defmodule BusterClaw.ProvidersClientTest do
  use BusterClaw.DataCase

  alias BusterClaw.Providers

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "applies default base URLs" do
    assert {:ok, provider} =
             Providers.create_provider(%{
               name: "router",
               type: "openrouter",
               model: "openai/gpt-5.4"
             })

    assert provider.base_url == "https://openrouter.ai/api/v1"
  end

  test "sets one active provider" do
    {:ok, first} = Providers.create_provider(%{name: "first", type: "ollama", model: "llama3"})
    {:ok, second} = Providers.create_provider(%{name: "second", type: "openai", model: "gpt-5.4"})

    assert {:ok, active} = Providers.set_active_provider(first)
    assert active.id == first.id
    assert Providers.active_provider().id == first.id

    assert {:ok, active} = Providers.set_active_provider(second)
    assert active.id == second.id
    assert Providers.active_provider().id == second.id
    refute Providers.get_provider!(first.id).active
  end

  test "routes OpenAI-compatible chat through callback contract" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "connected"
            }
          }
        ]
      })
    end)

    {:ok, provider} =
      Providers.create_provider(%{
        name: "openai",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret"
      })

    assert :ok =
             Providers.chat(provider, [%{role: "user", content: "hello"}], fn chunk ->
               send(self(), {:chunk, chunk})
             end)

    assert_received {:chunk, "connected"}
    assert {:ok, "connected"} = Providers.test_provider(provider)
  end

  test "routes Ollama chat through callback contract" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{message: %{content: "local response"}})
    end)

    {:ok, provider} =
      Providers.create_provider(%{
        name: "ollama",
        type: "ollama",
        model: "llama3"
      })

    assert :ok =
             Providers.chat(provider, [%{role: "user", content: "hello"}], fn chunk ->
               send(self(), {:chunk, chunk})
             end)

    assert_received {:chunk, "local response"}
  end

  test "routes Anthropic chat through callback contract" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{
        content: [
          %{text: "anthropic response"}
        ]
      })
    end)

    {:ok, provider} =
      Providers.create_provider(%{
        name: "anthropic",
        type: "anthropic",
        model: "claude-sonnet-4.5",
        api_key: "secret"
      })

    assert :ok =
             Providers.chat(provider, [%{role: "user", content: "hello"}], fn chunk ->
               send(self(), {:chunk, chunk})
             end)

    assert_received {:chunk, "anthropic response"}
  end

  test "returns an error when no active provider exists" do
    assert {:error, :no_active_provider} =
             Providers.chat_with_active([%{role: "user", content: "hello"}], fn _chunk -> :ok end)
  end
end
