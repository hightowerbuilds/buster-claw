defmodule BusterClaw.Dispatch.Item do
  @moduledoc "A durable Dispatch queue item created from trusted inbound requests."

  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Orchestration.{Shift, ShiftAssignment}

  @statuses ~w(queued claimed running done failed blocked cancelled)
  @strategies ~w(single swarm)

  @derive {Jason.Encoder,
           only: [
             :id,
             :source,
             :source_account,
             :sender,
             :trusted_sender,
             :trusted,
             :auth_status,
             :gmail_message_id,
             :gmail_thread_id,
             :gmail_rfc_message_id,
             :subject,
             :request_summary,
             :request_body_excerpt,
             :recommended_agent,
             :recommended_role_key,
             :risk,
             :status,
             :strategy,
             :shift_id,
             :shift_assignment_id,
             :dedupe_key,
             :claimed_by,
             :claimed_at,
             :started_at,
             :finished_at,
             :heartbeat_at,
             :outcome,
             :notes,
             :metadata,
             :inserted_at,
             :updated_at
           ]}
  schema "dispatch_items" do
    field :source, :string
    field :source_account, :string
    field :sender, :string
    field :trusted_sender, :string
    field :trusted, :boolean, default: false
    field :auth_status, :string, default: "unverified"
    field :gmail_message_id, :string
    field :gmail_thread_id, :string
    field :gmail_rfc_message_id, :string
    field :subject, :string
    field :request_summary, :string
    field :request_body_excerpt, :string
    field :recommended_agent, :string
    field :recommended_role_key, :string
    field :risk, :string
    field :status, :string, default: "queued"
    field :strategy, :string, default: "single"
    field :dedupe_key, :string
    field :claimed_by, :string
    field :claimed_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :outcome, :string
    field :notes, :string
    field :metadata, :map, default: %{}

    belongs_to :shift, Shift
    belongs_to :shift_assignment, ShiftAssignment

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :source,
      :source_account,
      :sender,
      :trusted_sender,
      :trusted,
      :auth_status,
      :gmail_message_id,
      :gmail_thread_id,
      :gmail_rfc_message_id,
      :subject,
      :request_summary,
      :request_body_excerpt,
      :recommended_agent,
      :recommended_role_key,
      :risk,
      :status,
      :strategy,
      :shift_id,
      :shift_assignment_id,
      :dedupe_key,
      :claimed_by,
      :claimed_at,
      :started_at,
      :finished_at,
      :heartbeat_at,
      :outcome,
      :notes,
      :metadata
    ])
    |> validate_required([:source, :status, :dedupe_key])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:strategy, @strategies)
    |> unique_constraint(:dedupe_key)
  end

  def statuses, do: @statuses
  def strategies, do: @strategies
end
