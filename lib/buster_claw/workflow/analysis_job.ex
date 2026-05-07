defmodule BusterClaw.Workflow.AnalysisJob do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Library.{Document, Report}
  alias BusterClaw.Providers.Provider

  @statuses ~w(queued analyzing done failed cancelled)

  schema "analysis_jobs" do
    belongs_to :document, Document
    belongs_to :report, Report
    belongs_to :provider, Provider

    field :status, :string, default: "queued"
    field :progress, :integer, default: 0
    field :model, :string
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :document_id,
      :report_id,
      :provider_id,
      :status,
      :progress,
      :model,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:document_id, :status, :progress])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
