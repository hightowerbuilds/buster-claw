defmodule BusterClaw.Workflow.DeliveryAttempt do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Automation.DeliveryDestination
  alias BusterClaw.Library.Report

  @statuses ~w(queued sending sent failed)

  schema "delivery_attempts" do
    belongs_to :delivery_destination, DeliveryDestination
    belongs_to :report, Report

    field :title, :string
    field :status, :string, default: "queued"
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :delivery_destination_id,
      :report_id,
      :title,
      :status,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:title, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
