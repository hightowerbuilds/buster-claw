defmodule BusterClaw.Provider.Anthropic do
  @moduledoc "Anthropic messages provider."

  @behaviour BusterClaw.Providers.Backend

  alias BusterClaw.AgentTools
  alias BusterClaw.Provider.HTTP

  @max_tool_iterations 6

  @impl true
  def chat(provider, messages, on_chunk) do
    {system, user_messages} = split_system(messages)

    payload =
      %{
        model: provider.model,
        max_tokens: 8192,
        messages: user_messages
      }
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

  @doc """
  Agentic chat with tool support. Runs the model in a loop, executing safe-tier
  `BusterClaw.Commands` calls as tools, until the model produces a final
  text response (or `@max_tool_iterations` rounds elapse).
  """
  def chat_agentic(provider, messages, on_chunk) do
    {system, normalized} = split_system(messages)
    tools = AgentTools.anthropic_tools()
    agent_loop(provider, system, normalized, tools, on_chunk, @max_tool_iterations)
  end

  defp agent_loop(_provider, _system, _messages, _tools, _on_chunk, 0) do
    {:error, :max_tool_iterations}
  end

  defp agent_loop(provider, system, messages, tools, on_chunk, remaining) do
    payload =
      %{
        model: provider.model,
        max_tokens: 8192,
        messages: messages,
        tools: tools
      }
      |> maybe_put_system(system)

    case HTTP.post(endpoint(provider),
           json: payload,
           headers: headers(provider),
           receive_timeout: 60_000
         ) do
      {:ok, %{"stop_reason" => "tool_use", "content" => content} = _body} ->
        tool_results =
          content
          |> Enum.filter(&(&1["type"] == "tool_use"))
          |> Enum.map(&run_tool_call/1)

        assistant_msg = %{role: "assistant", content: content}
        user_msg = %{role: "user", content: tool_results}

        agent_loop(
          provider,
          system,
          messages ++ [assistant_msg, user_msg],
          tools,
          on_chunk,
          remaining - 1
        )

      {:ok, %{"content" => content}} ->
        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map(& &1["text"])
          |> Enum.join("\n")

        if text != "", do: on_chunk.(text)
        :ok

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      error ->
        error
    end
  end

  defp run_tool_call(%{"id" => id, "name" => name, "input" => input}) do
    {is_error, content} =
      case AgentTools.execute(name, input) do
        {:ok, text} -> {false, text}
        {:error, text} -> {true, text}
      end

    %{
      type: "tool_result",
      tool_use_id: id,
      content: content,
      is_error: is_error
    }
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

  defp endpoint(provider), do: String.trim_trailing(base_url(provider), "/") <> "/v1/messages"

  defp base_url(%{base_url: url}) when url not in [nil, ""], do: url
  defp base_url(_provider), do: "https://api.anthropic.com"

  defp headers(provider) do
    [
      {"content-type", "application/json"},
      {"anthropic-version", "2023-06-01"}
    ]
    |> maybe_key(provider.api_key)
  end

  defp maybe_key(headers, key) when key in [nil, ""], do: headers
  defp maybe_key(headers, key), do: [{"x-api-key", key} | headers]

  defp split_system(messages) do
    system =
      messages
      |> Enum.filter(&(&1.role == "system" or &1[:role] == "system"))
      |> Enum.map(&message_content/1)
      |> Enum.join("\n\n")

    user_messages =
      messages
      |> Enum.reject(&(&1.role == "system" or &1[:role] == "system"))
      |> Enum.map(fn message ->
        %{role: message_role(message), content: message_content(message)}
      end)

    {system, user_messages}
  end

  defp maybe_put_system(payload, ""), do: payload
  defp maybe_put_system(payload, system), do: Map.put(payload, :system, system)

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => role}), do: role

  defp message_content(%{content: content}), do: content
  defp message_content(%{"content" => content}), do: content

  defp extract_content(%{"content" => [%{"text" => content} | _]}) when is_binary(content),
    do: {:ok, content}

  defp extract_content(body), do: {:error, {:unexpected_response, body}}
end
