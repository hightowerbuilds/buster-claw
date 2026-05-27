defmodule BusterClaw.Google do
  @moduledoc "Google Workspace account storage and shared OAuth state."

  import Ecto.Query

  alias BusterClaw.Google.Account
  alias BusterClaw.Repo

  @topic "google"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  def list_accounts do
    Account
    |> order_by([account], asc: account.email)
    |> Repo.all()
    |> Enum.map(&Account.scrub/1)
  end

  def list_account_summaries do
    Enum.map(list_accounts(), &account_summary/1)
  end

  def get_account!(id), do: Account |> Repo.get!(id) |> Account.scrub()

  def get_account_by_email(email) when is_binary(email) do
    email = String.trim(email)

    Account
    |> where([account], account.email == ^email)
    |> Repo.one()
    |> case do
      nil -> nil
      account -> Account.scrub(account)
    end
  end

  def get_account_by_email(_email), do: nil

  def default_account do
    Account
    |> where([account], account.enabled == true)
    |> where([account], not is_nil(account.refresh_token_enc))
    |> order_by([account], asc: account.email)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      account -> Account.scrub(account)
    end
  end

  def upsert_account(attrs) do
    case get_account_by_email(Map.get(attrs, "email") || Map.get(attrs, :email)) do
      nil -> create_account(attrs)
      account -> update_account(account, attrs)
    end
  end

  def create_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
    |> scrub_and_broadcast(:created)
  end

  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
    |> scrub_and_broadcast(:updated)
  end

  def delete_account(%Account{} = account) do
    account
    |> Repo.delete()
    |> scrub_and_broadcast(:deleted)
  end

  def change_account(%Account{} = account \\ %Account{}, attrs \\ %{}) do
    Account.changeset(account, attrs)
  end

  def account_summary(%Account{} = account) do
    %{
      id: account.id,
      email: account.email,
      client_id: account.client_id,
      scopes: account.scopes,
      default_query: account.default_query,
      enabled: account.enabled,
      last_synced_at: account.last_synced_at,
      last_seen_history_id: account.last_seen_history_id,
      has_client_secret: present?(account.client_secret_enc),
      has_refresh_token: present?(account.refresh_token_enc),
      has_access_token: present?(account.access_token_enc),
      access_token_expires_at: account.access_token_expires_at
    }
  end

  defp scrub_and_broadcast({:ok, account}, event) do
    account = Account.scrub(account)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:google_account_changed, event, account})
    {:ok, account}
  end

  defp scrub_and_broadcast(other, _event), do: other

  defp present?(value), do: value not in [nil, ""]
end
