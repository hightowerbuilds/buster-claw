defmodule BusterClaw.BrowserControl.Secret do
  @moduledoc """
  One `$secret.<name>` entry. `value` is `BusterClaw.Encrypted`, so it is
  ciphertext at rest and never appears in a dump of the database.

  See `BusterClaw.BrowserControl.Secrets` for why the store lives here rather
  than in a second Keychain integration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # The reference grammar `SecretRef` will actually match — anything outside it
  # could be stored and then never resolvable, which is a trap rather than a
  # feature.
  @name_re ~r/\A[a-z0-9_.-]+\z/

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
    |> validate_format(:name, @name_re,
      message: "must match $secret.<name>: lowercase letters, digits, _ . -"
    )
    |> validate_length(:name, max: 100)
    |> validate_length(:note, max: 200)
    |> unique_constraint(:name)
  end
end
