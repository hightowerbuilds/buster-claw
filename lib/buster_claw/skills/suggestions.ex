defmodule BusterClaw.Skills.Suggestions do
  @moduledoc """
  Proposed-skill store for Phase 3 self-improvement. The Analyzer files a
  suggestion per repeated command sequence via `record/1`; an operator reviews
  `list/1` and calls `approve/1` (which writes the enabled `skills/*.md`) or
  `reject/1`. Suggestions are **never** auto-enabled — that human gate is the
  safety property (see the threat model, T5).
  """
  import Ecto.Query

  alias BusterClaw.Repo
  alias BusterClaw.Skills
  alias BusterClaw.Skills.Suggestion

  @doc """
  File (or re-confirm) a proposed skill for a command sequence. If a pending
  suggestion already exists for this signature, bump its occurrence count and
  `last_seen` rather than duplicate. `attrs` needs `:signature`, `:name`,
  `:steps` (a list), and optionally `:description` / `:caller` / `:last_seen`.
  """
  def record(%{signature: signature, steps: steps} = attrs) do
    case pending_by_signature(signature) do
      nil ->
        %Suggestion{}
        |> Suggestion.changeset(%{
          signature: signature,
          name: attrs[:name],
          description: attrs[:description],
          steps_json: Jason.encode!(steps),
          caller: attrs[:caller],
          occurrences: Map.get(attrs, :occurrences, 1),
          last_seen: attrs[:last_seen],
          status: "pending"
        })
        |> Repo.insert()

      existing ->
        existing
        |> Suggestion.changeset(%{
          occurrences: existing.occurrences + Map.get(attrs, :occurrences, 1),
          last_seen: attrs[:last_seen] || existing.last_seen
        })
        |> Repo.update()
    end
  end

  @doc "List suggestions by status (default `\"pending\"`), most-frequent first."
  def list(opts \\ []) do
    status = Keyword.get(opts, :status, "pending")
    limit = Keyword.get(opts, :limit, 50)

    Suggestion
    |> where([s], s.status == ^status)
    |> order_by([s], desc: s.occurrences, desc: s.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def get(id), do: Repo.get(Suggestion, id)

  @doc "The proposed steps (decoded from JSON)."
  def steps(%Suggestion{steps_json: json}), do: Jason.decode!(json)

  @doc """
  Approve a pending suggestion: write the enabled `skills/<name>.md` and mark the
  suggestion approved. Returns `{:ok, name}`, `{:error, :not_found}`,
  `{:error, :not_pending}`, or a `Skills.write/1` error (e.g. `:exists`).
  """
  def approve(id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %Suggestion{status: "pending"} = suggestion ->
        attrs = %{
          name: suggestion.name,
          description: suggestion.description || "Approved from a repeated command sequence.",
          tier: :restricted,
          steps: steps(suggestion)
        }

        with {:ok, _path} <- Skills.write(attrs),
             {:ok, _} <- set_status(suggestion, "approved") do
          {:ok, suggestion.name}
        end

      %Suggestion{} ->
        {:error, :not_pending}
    end
  end

  @doc "Reject a pending suggestion (kept for history)."
  def reject(id) do
    case get(id) do
      nil -> {:error, :not_found}
      %Suggestion{status: "pending"} = s -> set_status(s, "rejected")
      %Suggestion{} -> {:error, :not_pending}
    end
  end

  defp set_status(suggestion, status) do
    suggestion |> Suggestion.changeset(%{status: status}) |> Repo.update()
  end

  defp pending_by_signature(signature) do
    Suggestion
    |> where([s], s.signature == ^signature and s.status == "pending")
    |> Repo.one()
  end
end
