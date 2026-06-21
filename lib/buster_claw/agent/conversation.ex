defmodule BusterClaw.Agent.Conversation do
  @moduledoc "A chat conversation (one tab). String `id` doubles as the `conv_id`."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "agent_conversations" do
    field :title, :string
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:id, :title, :archived_at])
    |> validate_required([:id, :title])
    |> validate_length(:id, min: 1, max: 128)
  end
end
