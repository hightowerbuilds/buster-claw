defmodule BusterClaw.Commands.Skills do
  @moduledoc "Skill analysis and suggestion-review commands. Delegated to from `BusterClaw.Commands`."

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Analyzer
  alias BusterClaw.Skills.Suggestions

  def skill_analyze(args) do
    # Only override the configured threshold when the caller explicitly sets one.
    opts =
      case Map.get(args, "min_occurrences") do
        nil -> []
        raw -> [analyzer_min_occurrences: to_int(raw)]
      end

    {:ok, Analyzer.scan(opts)}
  end

  def skill_suggestions(args) do
    opts =
      [limit: normalize_limit(Map.get(args, "limit"))]
      |> maybe_put(:status, Map.get(args, "status"))

    {:ok, Enum.map(Suggestions.list(opts), &suggestion_view/1)}
  end

  def skill_suggestion_approve(%{"id" => id}) do
    case Suggestions.approve(to_int(id)) do
      {:ok, name} -> {:ok, %{approved: name}}
      {:error, reason} -> {:error, reason}
    end
  end

  def skill_suggestion_approve(_args), do: {:error, :missing_id}

  def skill_suggestion_reject(%{"id" => id}) do
    case Suggestions.reject(to_int(id)) do
      {:ok, _} -> {:ok, %{rejected: to_int(id)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def skill_suggestion_reject(_args), do: {:error, :missing_id}

  defp suggestion_view(s) do
    %{
      id: s.id,
      name: s.name,
      signature: s.signature,
      description: s.description,
      occurrences: s.occurrences,
      status: s.status
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> 0
    end
  end

  defp to_int(_), do: 0
end
