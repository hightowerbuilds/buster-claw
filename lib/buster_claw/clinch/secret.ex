defmodule BusterClaw.Clinch.Secret do
  @moduledoc """
  One stored credential of a writable kind.

  Two kinds live here. `:sign_in` is the values an Agent Mode run types as
  `$secret.<name>`. `:service_key` is the app's own credentials — Twilio, the
  Supabase service role, Finnhub — which moved out of `runtime.exs` in Phase 3 so
  they could be rotated and revoked, which an environment variable never could be.

  **A name is unique within its kind, not globally.** A service key called
  `twilio` and a sign-in value called `twilio` are different credentials; making
  them collide would be an accident waiting rather than a safeguard.

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
    field :kind, :string, default: "sign_in"
    field :name, :string
    field :value, BusterClaw.Encrypted
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:kind, :name, :value, :note])
    |> validate_required([:kind, :name, :value])
    |> validate_inclusion(:kind, Enum.map(Types.managed_kinds(), &Atom.to_string/1),
      message: "is not a kind the Clinch can write"
    )
    |> validate_format(:name, Types.name_format(),
      message: "must match $secret.<name>: lowercase letters, digits, _ . -"
    )
    |> validate_length(:name, max: Types.max_name_length())
    |> validate_length(:note, max: Types.max_note_length())
    |> unique_constraint([:kind, :name])
  end
end
