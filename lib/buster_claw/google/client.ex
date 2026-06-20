defmodule BusterClaw.Google.Client do
  @moduledoc "Authenticated Google Workspace HTTP client with token refresh."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.OAuth

  @gmail_base_url "https://gmail.googleapis.com/gmail/v1"
  @drive_upload_base_url "https://www.googleapis.com/upload/drive/v3"
  @refresh_margin_seconds 60

  def get_json(%Account{} = account, path, opts \\ []) do
    request_json_with_token(account, :get, path, opts)
  end

  def post_json(%Account{} = account, path, body, opts \\ []) do
    request_json_with_token(account, :post, path, Keyword.put(opts, :json, body))
  end

  def put_json(%Account{} = account, path, body, opts \\ []) do
    request_json_with_token(account, :put, path, Keyword.put(opts, :json, body))
  end

  def patch_json(%Account{} = account, path, body, opts \\ []) do
    request_json_with_token(account, :patch, path, Keyword.put(opts, :json, body))
  end

  @doc """
  Issue a DELETE. Tolerates an empty `204 No Content` body (returns `{:ok, ""}`).
  """
  def delete(%Account{} = account, path, opts \\ []) do
    request_json_with_token(account, :delete, path, opts)
  end

  @doc """
  Upload media (Drive). `attrs` is `%{metadata: map, data: binary, content_type: string}`
  and is sent as a `multipart/related` body to the multipart upload host, so it
  bypasses JSON body encoding. Token refresh + 401 retry still apply.
  """
  def upload(%Account{} = account, path, %{} = attrs, opts \\ []) do
    with {:ok, account, token} <- account_token(account, opts) do
      run_with_refresh(
        fn acct, tok -> request_upload(acct, path, tok, attrs, opts) end,
        account,
        token,
        opts
      )
    end
  end

  defp request_json_with_token(%Account{} = account, method, path, opts) do
    with {:ok, account, token} <- account_token(account, opts) do
      run_with_refresh(
        fn acct, tok -> request_json(acct, method, path, tok, opts) end,
        account,
        token,
        opts
      )
    end
  end

  # Run a request closure; on a 401 refresh the token once and retry. The closure
  # takes `(account, token)` so it works for both JSON requests and media uploads.
  defp run_with_refresh(request_fun, account, token, opts) do
    case request_fun.(account, token) do
      {:error, {:unauthorized, _account_id}} ->
        with {:ok, refreshed} <- OAuth.refresh_access_token(account, opts),
             {:ok, new_token} <- Account.decrypt(refreshed, :access_token) do
          request_fun.(refreshed, new_token)
        end

      result ->
        result
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
    request_options =
      [
        method: method,
        url: endpoint(path, opts),
        headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}],
        params: Keyword.get(opts, :params, []),
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000),
        retry: false
      ]
      |> Keyword.merge(merged_req_options(opts))
      |> maybe_put_json(opts)

    Req.request(request_options)
    |> handle_response(account, opts)
  end

  defp request_upload(%Account{} = account, path, token, attrs, opts) do
    boundary = upload_boundary()

    body =
      related_body(
        boundary,
        Map.get(attrs, :metadata, %{}),
        Map.fetch!(attrs, :data),
        Map.get(attrs, :content_type, "application/octet-stream")
      )

    upload_opts = Keyword.put_new(opts, :base_url, @drive_upload_base_url)

    request_options =
      [
        method: :post,
        url: endpoint(path, upload_opts),
        headers: [
          {"authorization", "Bearer #{token}"},
          {"content-type", "multipart/related; boundary=#{boundary}"},
          {"accept", "application/json"}
        ],
        params: [{"uploadType", "multipart"}] ++ Keyword.get(opts, :params, []),
        body: body,
        receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
        retry: false
      ]
      |> Keyword.merge(merged_req_options(opts))

    Req.request(request_options)
    |> handle_response(account, opts)
  end

  defp handle_response(result, %Account{} = account, opts) do
    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, maybe_decode(body, opts)}

      {:ok, %{status: 401}} ->
        {:error, {:unauthorized, account.id}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:google_api_error, status, decode_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merged_req_options(opts) do
    []
    |> Keyword.merge(Application.get_env(:buster_claw, :google_req_options, []))
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
  end

  defp related_body(boundary, metadata, data, content_type) do
    metadata_json = Jason.encode!(metadata)

    "--#{boundary}\r\n" <>
      "Content-Type: application/json; charset=UTF-8\r\n\r\n" <>
      metadata_json <>
      "\r\n--#{boundary}\r\n" <>
      "Content-Type: #{content_type}\r\n\r\n" <>
      data <>
      "\r\n--#{boundary}--\r\n"
  end

  defp upload_boundary do
    "=_bc_upload_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp maybe_put_json(request_options, opts) do
    if Keyword.has_key?(opts, :json) do
      Keyword.put(request_options, :json, Keyword.fetch!(opts, :json))
    else
      request_options
    end
  end

  defp endpoint(path, opts) do
    base_url =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:buster_claw, :google_api_base_url, @gmail_base_url)

    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  # `decode: false` returns the raw body untouched — for `alt=media` downloads and
  # Docs/Sheets exports, where the payload is file bytes, not JSON.
  defp maybe_decode(body, opts) do
    if Keyword.get(opts, :decode, true), do: decode_body(body), else: body
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
