defmodule BusterClaw.Commands.Memory do
  @moduledoc "Agent memory search command. Delegated to from `BusterClaw.Commands`."

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Memory

  def memory_search(%{"query" => query} = args) when is_binary(query) do
    limit = normalize_limit(Map.get(args, "limit"))

    case Memory.search(query, limit: limit) do
      {:ok, summaries} -> {:ok, Enum.map(summaries, &memory_view/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  def memory_search(_args), do: {:error, :empty_query}

  defp memory_view(summary) do
    %{
      goal: summary.goal,
      outcome: summary.outcome,
      detail: summary.detail,
      agent: summary.agent,
      provenance: summary.provenance,
      source: summary.source,
      at: summary.inserted_at
    }
  end
end
