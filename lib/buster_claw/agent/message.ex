defmodule BusterClaw.Agent.Message do
  @moduledoc """
  A persisted chat transcript message for a headless-Claude conversation.

  Written by `BusterClaw.Agent.Chat` (via `BusterClaw.Agent.Transcript`) as
  display-ready entries, so a conversation survives a page reload or an app
  restart. Append-only; never updated.

  `content` is the text already shown in the bubble — the `:meta` role holds the
  formatted "N turns · $cost" footer, `:error` holds the human error copy — so a
  reload reproduces the transcript without re-deriving anything.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(user assistant tool meta error)

  @derive {Jason.Encoder,
           only: [:id, :conv_id, :role, :content, :session_id, :cost_usd, :num_turns, :inserted_at]}
  schema "agent_chat_messages" do
    field :conv_id, :string
    field :role, :string
    field :content, :string
    field :session_id, :string
    field :cost_usd, :float
    field :num_turns, :integer

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conv_id, :role, :content, :session_id, :cost_usd, :num_turns])
    |> validate_required([:conv_id, :role, :content])
    |> validate_inclusion(:role, @roles)
  end

  def roles, do: @roles
end
