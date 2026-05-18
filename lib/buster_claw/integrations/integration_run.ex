defmodule BusterClaw.Integrations.IntegrationRun do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Integrations.Integration
  alias BusterClaw.Library.Document

  @triggers ~w(manual scheduler webhook)
  @statuses ~w(running ok error)

  schema "integration_runs" do
    belongs_to :integration, Integration
    belongs_to :document, Document

    field :trigger, :string
    field :status, :string
    field :records_fetched, :integer, default: 0
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def triggers, do: @triggers
  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :integration_id,
      :document_id,
      :trigger,
      :status,
      :records_fetched,
      :error,
      :started_at,
      :finished_at,
      :metadata
    ])
    |> validate_required([:integration_id, :trigger, :status, :records_fetched, :started_at])
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:records_fetched, greater_than_or_equal_to: 0)
  end
end
