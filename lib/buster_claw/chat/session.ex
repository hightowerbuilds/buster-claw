defmodule BusterClaw.Chat.Session do
  @moduledoc "GenServer-backed local chat session."

  use GenServer

  alias BusterClaw.Chat.Message
  alias BusterClaw.{Browser, Ingest, Integrations, MCP, Memory, Providers, Search}

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def messages(session_id), do: GenServer.call(via(session_id), :messages)

  def send_message(session_id, prompt),
    do: GenServer.cast(via(session_id), {:send_message, prompt})

  def clear(session_id), do: GenServer.cast(via(session_id), :clear)

  @impl true
  def init(session_id) do
    {:ok, %{session_id: session_id, messages: [], streaming?: false}}
  end

  @impl true
  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  @impl true
  def handle_cast(:clear, state) do
    broadcast(state.session_id, :cleared, %{})
    {:noreply, %{state | messages: [], streaming?: false}}
  end

  def handle_cast({:send_message, prompt}, state) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" ->
        {:noreply, state}

      String.starts_with?(prompt, "/") ->
        handle_command(prompt, append_user(state, prompt))

      state.streaming? ->
        {:noreply, state}

      true ->
        state = append_user(state, prompt)
        broadcast(state.session_id, :waiting, %{})
        send(self(), {:provider_result, provider_chat(state.messages)})
        {:noreply, %{state | streaming?: true}}
    end
  end

  @impl true
  def handle_info({:provider_result, {:ok, response}}, state) do
    broadcast(state.session_id, :token, %{chunk: response})
    broadcast(state.session_id, :done, %{content: response})
    {:noreply, append_assistant(%{state | streaming?: false}, response)}
  end

  def handle_info({:provider_result, {:error, reason}}, state) do
    message = "Error: #{inspect(reason)}"
    broadcast(state.session_id, :error, %{error: message})
    {:noreply, append_assistant(%{state | streaming?: false}, message)}
  end

  defp handle_command(prompt, state) do
    [command | rest] = String.split(prompt, " ", parts: 2)
    arg = rest |> List.first() |> to_string() |> String.trim()

    case String.downcase(command) do
      "/help" ->
        reply(state, help())

      "/status" ->
        reply(state, status())

      "/clear" ->
        handle_cast(:clear, state)

      "/remember" ->
        remember(state, arg)

      "/forget" ->
        forget(state, arg)

      "/memories" ->
        memories(state)

      "/ingest" ->
        ingest(state, arg)

      "/search" ->
        search(state, arg)

      "/browse" ->
        browse(state, arg)

      "/mcp" ->
        reply(state, "**MCP Servers**\n\n#{MCP.tool_summary()}")

      "/integrations" ->
        integrations(state)

      "/poll" ->
        poll_integration(state, arg)

      "/brief" ->
        monitoring_brief(state)

      _ ->
        reply(state, "Unknown command: `#{command}`. Type `/help` for available commands.")
    end
  end

  defp provider_chat(messages) do
    provider_messages =
      messages
      |> with_memory()
      |> Enum.map(&%{role: &1.role, content: &1.content})

    chunks = Agent.start_link(fn -> [] end)

    with {:ok, agent} <- chunks,
         :ok <-
           Providers.agentic_chat_with_active(provider_messages, fn chunk ->
             Agent.update(agent, &[chunk | &1])
           end) do
      response = agent |> Agent.get(&Enum.reverse/1) |> Enum.join()
      Agent.stop(agent)
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_memory(messages) do
    memories = Memory.list_memories()

    memory_text =
      case memories do
        [] -> "No memories saved."
        entries -> Enum.map_join(entries, "\n", &"- #{&1.text}")
      end

    [
      %Message{role: "system", content: "Persistent memory:\n#{memory_text}"},
      %Message{role: "system", content: "MCP context:\n#{MCP.tool_summary()}"}
      | messages
    ]
  end

  defp append_user(state, content) do
    message = %Message{role: "user", content: content}
    broadcast(state.session_id, :message, %{message: message})
    %{state | messages: state.messages ++ [message]}
  end

  defp append_assistant(state, content) do
    %{state | messages: state.messages ++ [%Message{role: "assistant", content: content}]}
  end

  defp reply(state, content) do
    broadcast(state.session_id, :token, %{chunk: content})
    broadcast(state.session_id, :done, %{content: content})
    {:noreply, append_assistant(state, content)}
  end

  defp remember(state, ""), do: reply(state, "Usage: `/remember <fact or pattern to save>`")

  defp remember(state, text) do
    {:ok, _memory} =
      Memory.create_memory(%{
        created_at: DateTime.utc_now() |> DateTime.truncate(:second),
        text: text
      })

    reply(state, "Remembered: #{text}")
  end

  defp forget(state, arg) do
    with {index, ""} <- Integer.parse(arg),
         memory when not is_nil(memory) <- Enum.at(Memory.list_memories(), index - 1),
         {:ok, _} <- Memory.delete_memory(memory) do
      reply(state, "Forgot memory ##{index}.")
    else
      _ -> reply(state, "Usage: `/forget <number>`")
    end
  end

  defp memories(state) do
    entries = Memory.list_memories()

    content =
      if entries == [] do
        "No memories saved."
      else
        entries
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {entry, index} ->
          "#{index}. [#{entry.created_at}] #{entry.text}"
        end)
      end

    reply(state, content)
  end

  defp ingest(state, ""), do: reply(state, "Usage: `/ingest <url>`")

  defp ingest(state, url) do
    source = %BusterClaw.Sources.Source{
      url: url,
      type: "article",
      tags: %{"items" => ["chat-ingest"]}
    }

    case Ingest.ingest_source(source) do
      {:ok, count, _items} -> reply(state, "Ingested #{count} documents from `#{url}`.")
      {:error, reason} -> reply(state, "Ingest failed: #{inspect(reason)}")
    end
  end

  defp search(state, ""), do: reply(state, "Usage: `/search <query>`")

  defp search(state, query) do
    case Search.search(query) do
      {:ok, results} ->
        reply(state, "**Search Results**\n\n#{Search.format_results(results)}")

      {:error, reason} ->
        reply(state, "Search failed: #{inspect(reason)}")
    end
  end

  defp browse(state, ""), do: reply(state, "Usage: `/browse <url>`")

  defp browse(state, url) do
    case Browser.fetch(url) do
      {:ok, page} ->
        excerpt =
          page.markdown
          |> String.slice(0, 1_200)
          |> String.trim()

        reply(state, "**Browser Fetch**\n\n#{page.title}\n#{page.url}\n\n#{excerpt}")

      {:error, reason} ->
        reply(state, "Browser fetch failed: #{inspect(reason)}")
    end
  end

  defp integrations(state) do
    entries = Integrations.list_integrations()

    content =
      if entries == [] do
        "No integrations configured."
      else
        entries
        |> Enum.map_join("\n", fn integration ->
          "- #{integration.name} (#{integration.service_type}): #{integration.last_status}"
        end)
      end

    reply(state, "**Integrations**\n\n#{content}")
  end

  defp poll_integration(state, ""), do: reply(state, "Usage: `/poll <integration name>`")

  defp poll_integration(state, name) do
    case Integrations.get_by_name(name) do
      nil ->
        reply(state, "Integration not found: `#{name}`")

      integration ->
        case Integrations.poll_integration(integration) do
          {:ok, run} ->
            reply(
              state,
              "Polled #{integration.name}: #{run.records_fetched} snapshot(s), status #{run.status}."
            )

          {:error, run} ->
            reply(state, "Poll failed for #{integration.name}: #{run.error}")
        end
    end
  end

  defp monitoring_brief(state) do
    case Integrations.generate_monitoring_brief() do
      {:ok, report} ->
        reply(state, "Monitoring brief generated: #{report.artifact_path}")

      {:error, reason} ->
        reply(state, "Monitoring brief failed: #{inspect(reason)}")
    end
  end

  defp status do
    active =
      case Providers.active_provider() do
        nil -> "none"
        provider -> "#{provider.name} (#{provider.type}: #{provider.model})"
      end

    """
    **Runtime Status**
    - Active provider: #{active}
    - Chat runtime: supervised GenServer session
    - Library root: #{BusterClaw.Library.library_root()}
    """
  end

  defp help do
    """
    **Available Commands**
    - `/status`
    - `/remember <text>`
    - `/forget <number>`
    - `/memories`
    - `/ingest <url>`
    - `/search <query>`
    - `/browse <url>`
    - `/mcp`
    - `/integrations`
    - `/poll <integration name>`
    - `/brief`
    - `/clear`
    - `/help`
    """
  end

  defp broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, topic(session_id), {event, payload})
  end

  def topic(session_id), do: "chat:#{session_id}"

  defp via(session_id), do: {:via, Registry, {BusterClaw.Chat.Registry, session_id}}
end
