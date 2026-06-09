defmodule BusterClaw.Automation.SchedulerJob do
  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(integrations_poll)

  schema "scheduler_jobs" do
    field :job_id, :string
    field :type, :string
    field :cron, :string
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :job_id,
      :type,
      :cron,
      :enabled,
      :last_run_at,
      :next_run_at,
      :last_error
    ])
    |> validate_required([:job_id, :type, :cron])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:job_id)
  end
end
