defmodule BusterClaw.Google.SelfTest do
  @moduledoc """
  Post-connect health check (GWS seamless-connect Phase 3): one cheap read per
  Workspace surface — Mail (Gmail profile), Calendar (calendar list), Drive
  (about) — so the scariest OAuth moment ("did it actually work?") is answered
  with named green checks seconds after connecting, and a scope problem is
  named up front instead of surfacing later as a mystery failure.

  The last result is persisted per account in `Settings`
  (`google.self_test.<account_id>`, a small JSON document) and exposed on
  `Google.account_summary/1` as `:self_test`, so the GWS panel always shows
  connection *health*, not just connection existence.
  """

  alias BusterClaw.Google
  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client
  alias BusterClaw.Settings

  @calendar_base_url "https://www.googleapis.com/calendar/v3"
  @drive_base_url "https://www.googleapis.com/drive/v3"

  @doc "Surfaces checked, in display order."
  def surfaces, do: [:mail, :calendar, :drive]

  @doc """
  Run the self-test, persist the result, and broadcast the account update so
  open panels re-render. Returns `%{mail: :ok | {:error, msg}, ...}`.
  """
  def run(%Account{} = account, opts \\ []) do
    results = Map.new(surfaces(), fn surface -> {surface, check(surface, account, opts)} end)

    document = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "results" =>
        Map.new(results, fn
          {surface, :ok} -> {Atom.to_string(surface), "ok"}
          {surface, {:error, message}} -> {Atom.to_string(surface), message}
        end)
    }

    Settings.put(key(account.id), Jason.encode!(document))
    Google.notify_account_updated(account)
    results
  end

  @doc """
  The last persisted result for an account:
  `%{at: iso8601 | nil, results: %{"mail" => "ok" | error_message, ...}}`, or
  `nil` when the self-test has never run.
  """
  def last(account_id) do
    with raw when is_binary(raw) and raw != "" <- Settings.get(key(account_id)),
         {:ok, %{"results" => %{} = results} = doc} <- Jason.decode(raw) do
      %{at: doc["at"], results: results}
    else
      _ -> nil
    end
  end

  @doc "Drop an account's persisted result (account deletion cleanup)."
  def clear(account_id) do
    Settings.delete(key(account_id))
    :ok
  end

  @doc "True when every persisted surface reads \"ok\" (nil when never run)."
  def healthy?(account_id) do
    case last(account_id) do
      nil -> nil
      %{results: results} -> results != %{} and Enum.all?(results, fn {_k, v} -> v == "ok" end)
    end
  end

  defp key(account_id), do: "google.self_test.#{account_id}"

  defp check(:mail, account, opts) do
    account |> Client.get_json("users/me/profile", opts) |> probe()
  end

  defp check(:calendar, account, opts) do
    opts =
      opts
      |> Keyword.put(:base_url, @calendar_base_url)
      |> Keyword.put(:params, %{"maxResults" => 1})

    account |> Client.get_json("users/me/calendarList", opts) |> probe()
  end

  defp check(:drive, account, opts) do
    opts =
      opts
      |> Keyword.put(:base_url, @drive_base_url)
      |> Keyword.put(:params, %{"fields" => "user"})

    account |> Client.get_json("about", opts) |> probe()
  end

  defp probe({:ok, _body}), do: :ok
  defp probe({:error, reason}), do: {:error, describe(reason)}

  # Compact, user-facing failure line — the point is naming the broken surface
  # and the shape of the failure, not dumping a response body.
  defp describe({:google_api_error, status, body}) do
    case body do
      %{"error" => %{"message" => message}} when is_binary(message) ->
        "HTTP #{status}: #{message}"

      %{"error_description" => message} when is_binary(message) ->
        "HTTP #{status}: #{message}"

      _ ->
        "HTTP #{status}"
    end
  end

  defp describe({:google_oauth_error, status, _body}), do: "token refresh failed (HTTP #{status})"
  defp describe(:missing_refresh_token), do: "not authorized yet"
  defp describe(:missing_client_secret), do: "missing client secret"
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 120)
end
