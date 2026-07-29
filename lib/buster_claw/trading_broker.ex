defmodule BusterClaw.TradingBroker do
  @moduledoc """
  Persistence boundary for BusterClaw's direct Robinhood MCP connection.

  Provider account identifiers and OAuth tokens are encrypted at rest. Durable
  account relationships use an application HMAC rather than account numbers or
  last-four digits.
  """

  import Ecto.Query

  alias BusterClaw.Repo
  alias BusterClaw.TradingBroker.Account
  alias BusterClaw.TradingBroker.Connection
  alias BusterClaw.Vault

  @provider "robinhood"

  def connection, do: Repo.get_by(Connection, provider: @provider)

  def connection_with_accounts do
    case connection() do
      nil -> nil
      connection -> Repo.preload(connection, :accounts)
    end
  end

  def ensure_connection(attrs \\ %{}) do
    case connection() do
      nil ->
        attrs =
          attrs
          |> stringify_keys()
          |> Map.put("provider", @provider)
          |> Map.put_new("status", "disconnected")

        %Connection{}
        |> Connection.changeset(attrs)
        |> Repo.insert(log: false)

      connection ->
        update_connection(connection, attrs)
    end
  end

  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(attrs)
    |> Repo.update(log: false)
  end

  def put_client_id(client_id) when is_binary(client_id) and client_id != "" do
    ensure_connection(%{
      client_id: client_id,
      status: "authorizing",
      last_error: nil
    })
  end

  def put_tokens(token_response, now \\ DateTime.utc_now()) when is_map(token_response) do
    case value(token_response, "access_token") do
      access_token when is_binary(access_token) and access_token != "" ->
        with {:ok, connection} <- ensure_connection() do
          update_connection(
            connection,
            token_attrs(connection, token_response, access_token, now)
          )
        end

      _other ->
        {:error, :missing_access_token}
    end
  end

  def mark_checked(status, error \\ nil, now \\ DateTime.utc_now())
      when status in ["connected", "reconnect_required", "error"] do
    case connection() do
      %Connection{} = connection ->
        update_connection(connection, %{
          status: status,
          last_checked_at: now,
          last_error: bounded_error(error)
        })

      nil ->
        {:error, :not_connected}
    end
  end

  def list_accounts do
    Account
    |> order_by([a], desc: a.agentic, asc: a.label)
    |> Repo.all()
  end

  def agentic_account do
    Account
    |> where([a], a.agentic and a.can_trade)
    |> order_by([a], asc: a.id)
    |> limit(1)
    |> Repo.one()
  end

  def get_account_by_key(account_key) when is_binary(account_key),
    do: Repo.get_by(Account, account_key: account_key)

  def replace_accounts(%Connection{} = connection, accounts, now \\ DateTime.utc_now())
      when is_list(accounts) do
    Repo.transaction(fn ->
      keep_keys =
        Enum.reduce_while(accounts, [], fn account, keys ->
          with {:ok, attrs} <- normalize_account(connection, account, now),
               {:ok, _stored} <- upsert_account(attrs) do
            {:cont, [attrs.account_key | keys]}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      from(a in Account,
        where: a.connection_id == ^connection.id and a.account_key not in ^keep_keys
      )
      |> Repo.delete_all()

      list_accounts()
    end)
  end

  defp upsert_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert(
      log: false,
      on_conflict:
        {:replace,
         [
           :broker_account_id,
           :label,
           :agentic,
           :can_trade,
           :metadata,
           :broker_timestamp,
           :fetched_at,
           :updated_at
         ]},
      conflict_target: [:connection_id, :account_key]
    )
  end

  defp normalize_account(connection, account, now) when is_map(account) do
    case optional_binary(account, ["account_number", "account_id", "id"]) do
      nil ->
        {:error, :broker_account_missing_id}

      broker_id ->
        label =
          optional_binary(account, [
            "nickname",
            "label",
            "name",
            "brokerage_account_type",
            "account_type"
          ]) || "Brokerage account"

        agentic = agentic_allowed?(account)
        account_state = optional_binary(account, ["state", "status"])

        can_trade =
          agentic and account_state in [nil, "active"] and
            not truthy?(value_any(account, ["deactivated", "permanently_deactivated"]))

        {:ok,
         %{
           connection_id: connection.id,
           account_key: Vault.fingerprint("robinhood-account", broker_id),
           broker_account_id: broker_id,
           label: label,
           agentic: agentic,
           can_trade: can_trade,
           metadata: safe_account_metadata(account),
           broker_timestamp:
             parse_datetime(value_any(account, ["updated_at", "broker_timestamp"])),
           fetched_at: now
         }}
    end
  end

  defp normalize_account(_connection, _account, _now), do: {:error, :invalid_broker_account}

  defp safe_account_metadata(account) do
    %{
      "account_type" => optional_binary(account, ["brokerage_account_type", "account_type"]),
      "trading_type" => optional_binary(account, ["type"]),
      "status" => optional_binary(account, ["state", "status"]),
      "affiliate" => optional_binary(account, ["affiliate"]),
      "is_default" => boolean_or_nil(value_any(account, ["is_default"])),
      "currency" => optional_binary(account, ["currency"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp token_attrs(connection, response, access_token, now) do
    expires_in = parse_positive_integer(value(response, "expires_in")) || 3600
    refresh_token = value(response, "refresh_token")

    %{
      access_token: access_token,
      refresh_token:
        if(is_binary(refresh_token) and refresh_token != "",
          do: refresh_token,
          else: connection.refresh_token
        ),
      access_token_expires_at: DateTime.add(now, expires_in, :second),
      scope: value(response, "scope") || connection.scope,
      status: "authorizing",
      connected_at: connection.connected_at || now,
      last_checked_at: now,
      last_error: nil
    }
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp optional_binary(map, keys) do
    case value_any(map, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp truthy?(value), do: value in [true, "true", "enabled", "active", 1]

  defp agentic_allowed?(account) do
    case fetch_value(account, "agentic_allowed") do
      {:ok, value} ->
        truthy?(value)

      :error ->
        truthy?(value_any(account, ["agentic", "is_agentic", "agentic_enabled"]))
    end
  end

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil

  defp value_any(map, keys), do: Enum.find_value(keys, &value(map, &1))

  defp value(map, key) when is_map(map) and is_binary(key) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        try do
          Map.fetch(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> :error
        end
    end
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp bounded_error(nil), do: nil
  defp bounded_error(error) when is_binary(error), do: String.slice(error, 0, 1_000)
  defp bounded_error(error) when is_atom(error), do: error |> Atom.to_string() |> bounded_error()
  defp bounded_error(_error), do: "broker connection failed"
end
