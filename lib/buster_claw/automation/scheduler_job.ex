defmodule BusterClaw.Automation.SchedulerJob do
  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(ingest analyze full digest custom integrations_poll monitoring_brief)

  schema "scheduler_jobs" do
    field :job_id, :string
    field :type, :string
    field :cron, :string
    field :enabled, :boolean, default: true
    field :custom_cmd, :string
    field :deliver_to, :string
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
      :custom_cmd,
      :deliver_to,
      :last_run_at,
      :next_run_at,
      :last_error
    ])
    |> validate_required([:job_id, :type, :cron])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:job_id)
  end
end
