defmodule BusterClaw.Provider.OpenAICompatible do
  @moduledoc "OpenAI-compatible chat completions provider."

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
             headers: headers(provider),
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

  defp endpoint(provider),
    do: String.trim_trailing(base_url(provider), "/") <> "/chat/completions"

  defp base_url(%{base_url: url, type: "openrouter"}) when url in [nil, ""],
    do: "https://openrouter.ai/api/v1"

  defp base_url(%{base_url: url, type: "openai"}) when url in [nil, ""],
    do: "https://api.openai.com/v1"

  defp base_url(%{base_url: url}) when url not in [nil, ""], do: url
  defp base_url(_provider), do: "https://api.openai.com/v1"

  defp headers(provider) do
    [{"content-type", "application/json"}]
    |> maybe_auth(provider.api_key)
  end

  defp maybe_auth(headers, key) when key in [nil, ""], do: headers
  defp maybe_auth(headers, key), do: [{"authorization", "Bearer #{key}"} | headers]

  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content),
       do: {:ok, content}

  defp extract_content(%{"choices" => [%{"delta" => %{"content" => content}} | _]})
       when is_binary(content),
       do: {:ok, content}

  defp extract_content(body), do: {:error, {:unexpected_response, body}}
end
