defmodule BusterClaw.Google do
  @moduledoc "Google Workspace account storage and shared OAuth state."

  import Ecto.Query

  alias BusterClaw.Google.Account
  alias BusterClaw.Repo
  alias BusterClaw.Sentinel
  alias BusterClaw.Settings

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
    # Drop the account's derived-state keys so a future account with a reused
    # id can't inherit stale health/reconnect flags.
    Settings.delete(reconnect_key(account.id))
    BusterClaw.Google.SelfTest.clear(account.id)

    account
    |> Repo.delete()
    |> scrub_and_broadcast(:deleted)
  end

  # --- token health (GWS seamless-connect Phase 4) ------------------------

  @doc """
  Flag that an account's refresh token is dead (`invalid_grant`) and only a
  manual reconnect can revive it. Emits a Sentinel `google_auth` event —
  during the unverified-OAuth beta this fires roughly weekly (Google expires
  Testing-status refresh tokens after 7 days), so the message says what to do
  rather than reading as a crash.
  """
  def mark_reconnect_needed(%Account{} = account) do
    already? = reconnect_needed?(account.id)
    Settings.put(reconnect_key(account.id), DateTime.utc_now() |> DateTime.to_iso8601())

    unless already? do
      Sentinel.observe(
        :google_auth,
        "Google session for #{account.email} expired — reconnect in Settings → GWS to resume mail/calendar work.",
        %{account_id: account.id, email: account.email, reason: "invalid_grant"}
      )

      notify_account_updated(account)
    end

    :ok
  end

  @doc "Clear the reconnect flag (any successful token exchange/refresh)."
  def clear_reconnect_needed(%Account{} = account) do
    if reconnect_needed?(account.id) do
      Settings.delete(reconnect_key(account.id))
      notify_account_updated(account)
    end

    :ok
  end

  @doc "Whether the account's Google session needs a manual reconnect."
  def reconnect_needed?(account_id), do: Settings.get(reconnect_key(account_id)) not in [nil, ""]

  @doc """
  Broadcast that an account's *derived* state (health, reconnect flag) changed
  without a row write — open panels re-render off the same message they get
  for real updates.
  """
  def notify_account_updated(%Account{} = account) do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      @topic,
      {:google_account_changed, :updated, Account.scrub(account)}
    )
  end

  defp reconnect_key(account_id), do: "google.reconnect_needed.#{account_id}"

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
      calendar_sync_token_calendars:
        account.calendar_sync_tokens |> normalize_map() |> Map.keys() |> Enum.sort(),
      has_client_secret: present?(account.client_secret_enc),
      has_refresh_token: present?(account.refresh_token_enc),
      has_access_token: present?(account.access_token_enc),
      access_token_expires_at: account.access_token_expires_at,
      reconnect_needed: reconnect_needed?(account.id),
      self_test: BusterClaw.Google.SelfTest.last(account.id)
    }
  end

  defp scrub_and_broadcast({:ok, account}, event) do
    account = Account.scrub(account)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:google_account_changed, event, account})
    {:ok, account}
  end

  defp scrub_and_broadcast(other, _event), do: other

  defp present?(value), do: value not in [nil, ""]
  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}
end
