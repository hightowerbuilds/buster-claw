defmodule BusterClaw.Google.Client do
  @moduledoc "Authenticated Google Workspace HTTP client with token refresh."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.OAuth

  @gmail_base_url "https://gmail.googleapis.com/gmail/v1"
  @refresh_margin_seconds 60

  def get_json(%Account{} = account, path, opts \\ []) do
    request_json_with_token(account, :get, path, opts)
  end

  def post_json(%Account{} = account, path, body, opts \\ []) do
    request_json_with_token(account, :post, path, Keyword.put(opts, :json, body))
  end

  defp request_json_with_token(%Account{} = account, method, path, opts) do
    with {:ok, account, token} <- account_token(account, opts) do
      account
      |> request_json(method, path, token, opts)
      |> maybe_refresh_and_retry(account, method, path, opts)
    end
  end

  defp account_token(%Account{} = account, opts) do
    if token_current?(account) do
      with {:ok, token} <- Account.decrypt(account, :access_token) do
        {:ok, account, token}
      end
    else
      with {:ok, account} <- OAuth.refresh_access_token(account, opts),
           {:ok, token} <- Account.decrypt(account, :access_token) do
        {:ok, account, token}
      end
    end
  end

  defp token_current?(%Account{access_token_expires_at: nil}), do: false

  defp token_current?(%Account{} = account) do
    case Account.decrypt(account, :access_token) do
      {:ok, token} when token not in [nil, ""] ->
        DateTime.compare(
          account.access_token_expires_at,
          DateTime.utc_now() |> DateTime.add(@refresh_margin_seconds, :second)
        ) == :gt

      _other ->
        false
    end
  end

  defp request_json(%Account{} = account, method, path, token, opts) do
    req_options =
      []
      |> Keyword.merge(Application.get_env(:buster_claw, :google_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    request_options =
      [
        method: method,
        url: endpoint(path, opts),
        headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}],
        params: Keyword.get(opts, :params, []),
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(req_options)
      |> maybe_put_json(opts)

    case Req.request(request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_body(body)}

      {:ok, %{status: 401}} ->
        {:error, {:unauthorized, account.id}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:google_api_error, status, decode_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_json(request_options, opts) do
    if Keyword.has_key?(opts, :json) do
      Keyword.put(request_options, :json, Keyword.fetch!(opts, :json))
    else
      request_options
    end
  end

  defp maybe_refresh_and_retry(
         {:error, {:unauthorized, _account_id}},
         account,
         method,
         path,
         opts
       ) do
    with {:ok, refreshed} <- OAuth.refresh_access_token(account, opts),
         {:ok, token} <- Account.decrypt(refreshed, :access_token) do
      request_json(refreshed, method, path, token, opts)
    end
  end

  defp maybe_refresh_and_retry(result, _account, _method, _path, _opts), do: result

  defp endpoint(path, opts) do
    base_url =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:buster_claw, :google_api_base_url, @gmail_base_url)

    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_body(body), do: body
end
