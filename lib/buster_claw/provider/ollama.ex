defmodule BusterClaw.Provider.Ollama do
  @moduledoc "Ollama chat provider."

  @behaviour BusterClaw.Providers.Backend

  alias BusterClaw.Provider.HTTP

  @impl true
  def chat(provider, messages, on_chunk) do
    payload = %{
      model: provider.model,
      messages: messages,
      stream: false
    }

    with {:ok, body} <-
           HTTP.post(endpoint(provider),
             json: payload,
             headers: [{"content-type", "application/json"}],
             receive_timeout: 45_000
           ),
         {:ok, content} <- extract_content(body) do
      on_chunk.(content)
      :ok
    end
  end

  @impl true
  def test_connection(provider) do
    case chat(provider, [%{role: "user", content: "Reply with only connected."}], fn chunk ->
           send(self(), {:chunk, chunk})
         end) do
      :ok ->
        receive do
          {:chunk, chunk} -> {:ok, String.trim(chunk)}
        after
          0 -> {:ok, "connected"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp endpoint(provider), do: String.trim_trailing(base_url(provider), "/") <> "/api/chat"

  defp base_url(%{base_url: url}) when url not in [nil, ""], do: url
  defp base_url(_provider), do: "http://127.0.0.1:11434"

  defp extract_content(%{"message" => %{"content" => content}}) when is_binary(content),
    do: {:ok, content}

  defp extract_content(%{"response" => content}) when is_binary(content), do: {:ok, content}
  defp extract_content(body), do: {:error, {:unexpected_response, body}}
end
