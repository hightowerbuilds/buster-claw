defmodule BusterClaw.Google.Account do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Google.Vault

  schema "google_accounts" do
    field :email, :string
    field :client_id, :string
    field :client_secret_enc, :binary
    field :refresh_token_enc, :binary
    field :access_token_enc, :binary
    field :access_token_expires_at, :utc_datetime
    field :scopes, :string
    field :default_query, :string
    field :last_synced_at, :utc_datetime
    field :last_seen_history_id, :string
    field :enabled, :boolean, default: true

    field :client_secret, :string, virtual: true
    field :refresh_token, :string, virtual: true
    field :access_token, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :email,
      :client_id,
      :client_secret,
      :refresh_token,
      :access_token,
      :access_token_expires_at,
      :scopes,
      :default_query,
      :last_synced_at,
      :last_seen_history_id,
      :enabled
    ])
    |> validate_required([:email, :client_id, :enabled])
    |> update_change(:email, &String.trim/1)
    |> update_change(:client_id, &String.trim/1)
    |> update_change(:scopes, &normalize_scopes/1)
    |> encrypt_change(:client_secret, :client_secret_enc)
    |> encrypt_change(:refresh_token, :refresh_token_enc)
    |> encrypt_change(:access_token, :access_token_enc)
    |> unique_constraint(:email)
  end

  def decrypt(%__MODULE__{} = account, :client_secret),
    do: Vault.decrypt(account.client_secret_enc)

  def decrypt(%__MODULE__{} = account, :refresh_token),
    do: Vault.decrypt(account.refresh_token_enc)

  def decrypt(%__MODULE__{} = account, :access_token), do: Vault.decrypt(account.access_token_enc)

  def scrub(%__MODULE__{} = account) do
    %{account | client_secret: nil, refresh_token: nil, access_token: nil}
  end

  defp encrypt_change(changeset, plaintext_field, encrypted_field) do
    case get_change(changeset, plaintext_field) do
      value when value in [nil, ""] ->
        changeset

      value ->
        changeset
        |> put_change(encrypted_field, Vault.encrypt!(value))
        |> put_change(plaintext_field, nil)
    end
  end

  defp normalize_scopes(nil), do: nil

  defp normalize_scopes(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
    |> Enum.join(" ")
  end
end
