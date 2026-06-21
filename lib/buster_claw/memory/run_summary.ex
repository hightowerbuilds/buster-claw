defmodule BusterClaw.Memory.RunSummary do
  @moduledoc """
  A structured record of one headless agent run (Phase 2, Tier 2 memory). Written
  at the end of each run so a later run can recall "what have I done with X before?"
  via `BusterClaw.Memory.search/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(completed failed error)

  schema "run_summaries" do
    field :goal, :string
    field :outcome, :string
    field :detail, :string
    field :agent, :string
    field :exit_status, :integer
    field :duration_ms, :integer
    field :provenance, :string
    field :shift_id, :integer
    field :source, :string, default: "dispatch"

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :goal,
      :outcome,
      :detail,
      :agent,
      :exit_status,
      :duration_ms,
      :provenance,
      :shift_id,
      :source
    ])
    |> validate_required([:goal, :outcome])
    |> validate_inclusion(:outcome, @outcomes)
  end
end
