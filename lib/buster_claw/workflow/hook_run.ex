defmodule BusterClaw.Workflow.HookRun do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Automation.Hook

  schema "hook_runs" do
    belongs_to :hook, Hook

    field :event, :string
    field :type, :string
    field :started_at, :utc_datetime
    field :duration_ms, :integer
    field :success, :boolean, default: false
    field :error, :string
    field :stdout, :string
    field :stderr, :string
    field :status_code, :integer
    field :payload, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :hook_id,
      :event,
      :type,
      :started_at,
      :duration_ms,
      :success,
      :error,
      :stdout,
      :stderr,
      :status_code,
      :payload
    ])
    |> validate_required([:event, :type, :started_at, :success])
  end
end
