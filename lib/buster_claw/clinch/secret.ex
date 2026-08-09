defmodule BusterClaw.Clinch.Secret do
  @moduledoc """
  One stored credential of a writable kind — today that means `:sign_in`, the
  values an Agent Mode run types as `$secret.<name>`.

  `value` is `BusterClaw.Encrypted`, so it is ciphertext at rest and never
  appears in a dump of the database. (Phase 0 closed the other half of that
  promise: the value used to reach `security_events` in the clear on the way
  *in*, which no amount of at-rest encryption would have helped.)

  The table is still `browser_secrets`. It was created when the store belonged to
  `BrowserControl`, and renaming it would be a migration that buys nothing — the
  module moved because the Clinch owns credential storage now, not because the
  bytes needed to.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Clinch.Types

  @type t :: %__MODULE__{}

  schema "browser_secrets" do
    field :name, :string
    field :value, BusterClaw.Encrypted
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :value, :note])
    |> validate_required([:name, :value])
    |> validate_format(:name, Types.name_format(),
      message: "must match $secret.<name>: lowercase letters, digits, _ . -"
    )
    |> validate_length(:name, max: Types.max_name_length())
    |> validate_length(:note, max: Types.max_note_length())
    |> unique_constraint(:name)
  end
end
