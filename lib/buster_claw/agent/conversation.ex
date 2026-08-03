defmodule BusterClaw.Agent.Conversation do
  @moduledoc "A chat conversation (one tab). String `id` doubles as the `conv_id`."
  use Ecto.Schema
  import Ecto.Changeset

  # `chat` is the neutral Trading kind: a conversation the operator has not
  # pointed at anything yet. It can be retyped to robinhood, research, or
  # chartbuild from inside the chat itself, which is why kind is a plain field
  # rather than something baked in at creation.
  @kinds ~w(home chat robinhood research chartbuild)

  @primary_key {:id, :string, autogenerate: false}
  schema "agent_conversations" do
    field :title, :string
    field :kind, :string, default: "home"
    field :docked, :boolean, default: false
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The conversation kinds. `home` is Home's chat strip; the rest are Trading tabs."
  def kinds, do: @kinds

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:id, :title, :kind, :docked, :archived_at])
    |> validate_required([:id, :title, :kind])
    |> validate_length(:id, min: 1, max: 128)
    # Validated rather than free-text: `kind` decides which surface a tab shows
    # on AND which tools its runs get, so a typo would put a research chat on
    # the broker's toolset or hide a tab from every list.
    |> validate_inclusion(:kind, @kinds)
  end
end
