defmodule BusterClaw.Agent.Conversation do
  @moduledoc "A chat conversation (one tab). String `id` doubles as the `conv_id`."
  use Ecto.Schema
  import Ecto.Changeset

  # `home` is the only kind left. `chat`, `robinhood` and `chartbuild` were the
  # Trading page's tab kinds and left with it on 08-08; their rows are
  # deleted by `20260808070000_drop_trading_stack`, which had to run BEFORE the
  # values left this list, because `validate_inclusion` below is what would
  # otherwise strand them (the same ordering lesson as the 08-03 research
  # retype).
  #
  # The field stays rather than collapsing to a boolean: it is the seam that
  # keeps a non-Home conversation out of Home's strip, and the next surface that
  # owns conversations will need it again.
  @kinds ~w(home)

  @primary_key {:id, :string, autogenerate: false}
  schema "agent_conversations" do
    field :title, :string
    field :kind, :string, default: "home"
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The conversation kinds. `home` is Home's chat strip."
  def kinds, do: @kinds

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:id, :title, :kind, :archived_at])
    |> validate_required([:id, :title, :kind])
    |> validate_length(:id, min: 1, max: 128)
    # Validated rather than free-text: `kind` decides which surface a tab shows
    # on AND which tools its runs get, so a typo would put a cached-only chat on
    # the broker's toolset or hide a tab from every list.
    |> validate_inclusion(:kind, @kinds)
  end
end
