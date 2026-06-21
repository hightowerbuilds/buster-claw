defmodule BusterClaw.Skills.Suggestion do
  @moduledoc """
  A proposed composition skill the Analyzer filed from a repeated command sequence
  (Phase 3). `status` moves `pending → approved | rejected`; approval writes the
  enabled `skills/*.md`. `steps_json` holds the ordered command list as JSON.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved rejected)

  schema "skill_suggestions" do
    field :signature, :string
    field :name, :string
    field :description, :string
    field :steps_json, :string
    field :occurrences, :integer, default: 1
    field :status, :string, default: "pending"
    field :caller, :string
    field :last_seen, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [
      :signature,
      :name,
      :description,
      :steps_json,
      :occurrences,
      :status,
      :caller,
      :last_seen
    ])
    |> validate_required([:signature, :name, :steps_json, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
