defmodule BusterClaw.Provider.Codex do
  @moduledoc "OpenAI Responses API provider for codex-* models."

  @behaviour BusterClaw.Providers.Backend

  alias BusterClaw.Provider.HTTP

  @impl true
  def chat(provider, messages, on_chunk) do
    payload = %{
      model: provider.model,
      input: Enum.map(messages, &to_input_item/1)
    }

    with {:ok, body} <-
           HTTP.post(endpoint(provider),
             json: payload,
             headers: headers(provider),
             receive_timeout: 120_000
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

  defp endpoint(provider), do: String.trim_trailing(base_url(provider), "/") <> "/responses"

  defp base_url(%{base_url: url}) when url not in [nil, ""], do: url
  defp base_url(_provider), do: "https://api.openai.com/v1"

  defp headers(provider) do
    [{"content-type", "application/json"}]
    |> maybe_auth(provider.api_key)
  end

  defp maybe_auth(headers, key) when key in [nil, ""], do: headers
  defp maybe_auth(headers, key), do: [{"authorization", "Bearer #{key}"} | headers]

  defp to_input_item(message),
    do: %{role: message_role(message), content: message_content(message)}

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => role}), do: role

  defp message_content(%{content: content}), do: content
  defp message_content(%{"content" => content}), do: content

  defp extract_content(%{"output_text" => text}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp extract_content(%{"output" => output}) when is_list(output) do
    text =
      output
      |> Enum.flat_map(fn item -> List.wrap(Map.get(item, "content", [])) end)
      |> Enum.map(&extract_part/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("")

    if text == "", do: {:error, {:unexpected_response, output}}, else: {:ok, text}
  end

  defp extract_content(body), do: {:error, {:unexpected_response, body}}

  defp extract_part(%{"type" => "output_text", "text" => text}) when is_binary(text), do: text
  defp extract_part(%{"text" => text}) when is_binary(text), do: text
  defp extract_part(_), do: ""
end
