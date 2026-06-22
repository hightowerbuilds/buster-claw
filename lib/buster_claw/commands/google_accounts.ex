defmodule BusterClaw.Commands.Google.Accounts do
  @moduledoc """
  Google Workspace account CRUD commands plus the shared account-resolution and
  argument-coercion helpers used by every per-service Google command module
  (Mail/Calendar/Drive/Docs/People).

  `with_google_account/2` is the choke point: each command resolves the target
  account (explicit `account_id`/`email`, else the default account) before
  calling the relevant `BusterClaw.Google.*` client. It is public so cross-domain
  callers (e.g. a Dispatch Gmail reply) can reuse account resolution without
  duplicating it; the `BusterClaw.Commands.Google` facade re-exports it.

  The generic `with_*` argument validators and `put_*`/`truthy?` coercers live
  here too so the service modules share one definition instead of each carrying a
  copy.
  """

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Google

  # -----------------------------------------------------------------------
  # Google Workspace accounts
  # -----------------------------------------------------------------------

  def google_account_list(_args \\ %{}), do: {:ok, Google.list_account_summaries()}

  def google_account_get(%{"id" => id}) do
    with_resource(Google, :get_account!, id, fn account ->
      {:ok, Google.account_summary(account)}
    end)
  end

  def google_account_create(args) do
    case Google.create_account(args) do
      {:ok, account} -> {:ok, Google.account_summary(account)}
      other -> other
    end
  end

  def google_account_update(%{"id" => id} = args) do
    with_resource(Google, :get_account!, id, fn account ->
      case Google.update_account(account, Map.delete(args, "id")) do
        {:ok, account} -> {:ok, Google.account_summary(account)}
        other -> other
      end
    end)
  end

  def google_account_delete(%{"id" => id}) do
    with_resource(Google, :get_account!, id, fn account ->
      case Google.delete_account(account) do
        {:ok, account} -> {:ok, Google.account_summary(account)}
        other -> other
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Account resolution + generic argument helpers (Google-specific)
  # ---------------------------------------------------------------------

  @doc """
  Resolve the target Google account (explicit `account_id`/`email`, else the
  default account) and run `fun` with it; `{:error, :no_google_account}` when
  none resolves. Public so cross-domain callers (e.g. a Dispatch Gmail reply)
  can reuse account resolution without duplicating it.
  """
  def with_google_account(args, fun) do
    cond do
      account_id = Map.get(args, "account_id") ->
        with_resource(Google, :get_account!, account_id, fun)

      email = Map.get(args, "email") ->
        case Google.get_account_by_email(email) do
          nil -> {:error, :not_found}
          account -> fun.(account)
        end

      account = Google.default_account() ->
        fun.(account)

      true ->
        {:error, :no_google_account}
    end
  end

  @doc """
  Resolve the Google account and require one non-empty string arg before calling
  `fun.(account, value)`.
  """
  def with_required(args, key, error, fun) do
    case Map.get(args, key) do
      value when value in [nil, ""] -> {:error, error}
      value -> with_google_account(args, fn account -> fun.(account, value) end)
    end
  end

  @doc """
  Require an id arg plus a non-empty `requests` list (Docs/Sheets/Slides
  batchUpdate), then call `fun.(account, id, requests)`.
  """
  def with_requests(args, id_key, id_error, fun) do
    requests = Map.get(args, "requests")

    cond do
      Map.get(args, id_key) in [nil, ""] ->
        {:error, id_error}

      not is_list(requests) or requests == [] ->
        {:error, :missing_requests}

      true ->
        with_google_account(args, fn account -> fun.(account, Map.get(args, id_key), requests) end)
    end
  end

  @doc "Coercion: truthy string/atom values used across the Google commands."
  def truthy?(value), do: value in [true, "true", "1", 1, "yes", "YES", "on", "ON"]

  @doc "Put a non-blank attr into a string-keyed map; drop blanks."
  def put_attr(attrs, _key, value) when value in [nil, ""], do: attrs
  def put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  @doc "Put a non-blank keyword opt; drop blanks."
  def put_opt(opts, _key, value) when value in [nil, ""], do: opts
  def put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Whether a confirmation-style flag is set to an affirmative value."
  def confirmed?(args, key) do
    Map.get(args, key) in [true, "true", "yes", "YES", "confirm", "CONFIRM"]
  end
end
