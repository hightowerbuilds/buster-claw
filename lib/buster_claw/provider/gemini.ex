defmodule BusterClaw.Provider.Gemini do
  @moduledoc "Google Gemini generateContent provider."

  @behaviour BusterClaw.Provider

  alias BusterClaw.Provider.HTTP

  @impl true
  def chat(provider, messages, on_chunk) do
    {system, conversation} = split_system(messages)

    payload =
      %{contents: Enum.map(conversation, &to_content/1)}
      |> maybe_put_system(system)

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

  defp endpoint(provider) do
    String.trim_trailing(base_url(provider), "/") <>
      "/models/" <> provider.model <> ":generateContent"
  end

  defp base_url(%{base_url: url}) when url not in [nil, ""], do: url
  defp base_url(_provider), do: "https://generativelanguage.googleapis.com/v1beta"

  defp headers(provider) do
    [{"content-type", "application/json"}]
    |> maybe_key(provider.api_key)
  end

  defp maybe_key(headers, key) when key in [nil, ""], do: headers
  defp maybe_key(headers, key), do: [{"x-goog-api-key", key} | headers]

  defp split_system(messages) do
    {system_messages, conversation} =
      Enum.split_with(messages, &(message_role(&1) == "system"))

    system =
      system_messages
      |> Enum.map(&message_content/1)
      |> Enum.join("\n\n")

    {system, conversation}
  end

  defp to_content(message) do
    role =
      case message_role(message) do
        "assistant" -> "model"
        "model" -> "model"
        _ -> "user"
      end

    %{role: role, parts: [%{text: message_content(message)}]}
  end

  defp maybe_put_system(payload, ""), do: payload

  defp maybe_put_system(payload, system),
    do: Map.put(payload, :systemInstruction, %{parts: [%{text: system}]})

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => role}), do: role

  defp message_content(%{content: content}), do: content
  defp message_content(%{"content" => content}), do: content

  defp extract_content(%{"candidates" => [candidate | _]}) do
    parts = get_in(candidate, ["content", "parts"]) || []

    text =
      parts
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("")

    if text == "", do: {:error, {:unexpected_response, candidate}}, else: {:ok, text}
  end

  defp extract_content(body), do: {:error, {:unexpected_response, body}}
end
