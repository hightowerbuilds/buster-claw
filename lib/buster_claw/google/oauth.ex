defmodule BusterClaw.Google.OAuth do
  @moduledoc "Google OAuth helpers for desktop loopback account authorization."

  alias BusterClaw.Google
  alias BusterClaw.Google.Account

  @authorize_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  # Full read/write across the Workspace surface the agent drives. `mail.google.com`,
  # `drive`, and `contacts` are Google *restricted* scopes (trigger OAuth verification
  # + the annual CASA security assessment before public distribution); the rest are
  # sensitive/non-sensitive. `mail.google.com` is a superset of gmail.readonly+compose.
  @default_scopes [
    "https://mail.google.com/",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/presentations",
    "https://www.googleapis.com/auth/contacts",
    "https://www.googleapis.com/auth/tasks"
  ]

  def default_scopes, do: @default_scopes
  def default_scope_string, do: Enum.join(@default_scopes, " ")

  def authorization_url(%Account{} = account, redirect_uri, state) do
    scope = authorization_scope(account.scopes)

    params = %{
      "access_type" => "offline",
      "client_id" => account.client_id,
      "include_granted_scopes" => "true",
      "prompt" => "consent",
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => scope,
      "state" => state
    }

    @authorize_endpoint <> "?" <> URI.encode_query(params)
  end

  defp authorization_scope(nil), do: default_scope_string()

  defp authorization_scope(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> Kernel.++(@default_scopes)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  def exchange_code(%Account{} = account, code, redirect_uri, opts \\ []) do
    with {:ok, client_secret} <- required_secret(account),
         {:ok, body} <-
           request_token(
             [
               client_id: account.client_id,
               client_secret: client_secret,
               code: code,
               grant_type: "authorization_code",
               redirect_uri: redirect_uri
             ],
             opts
           ),
         {:ok, attrs} <- token_attrs(body) do
      Google.update_account(account, attrs)
    end
  end

  def refresh_access_token(%Account{} = account, opts \\ []) do
    with {:ok, client_secret} <- required_secret(account),
         {:ok, refresh_token} <- required_refresh_token(account),
         {:ok, body} <-
           request_token(
             [
               client_id: account.client_id,
               client_secret: client_secret,
               grant_type: "refresh_token",
               refresh_token: refresh_token
             ],
             opts
           ),
         {:ok, attrs} <- token_attrs(body, keep_refresh_token?: false) do
      Google.update_account(account, attrs)
    end
  end

  defp required_secret(%Account{} = account) do
    case Account.decrypt(account, :client_secret) do
      {:ok, secret} when secret not in [nil, ""] -> {:ok, secret}
      {:ok, _} -> {:error, :missing_client_secret}
      error -> error
    end
  end

  defp required_refresh_token(%Account{} = account) do
    case Account.decrypt(account, :refresh_token) do
      {:ok, token} when token not in [nil, ""] -> {:ok, token}
      {:ok, _} -> {:error, :missing_refresh_token}
      error -> error
    end
  end

  defp request_token(form, opts) do
    req_options =
      []
      |> Keyword.merge(Application.get_env(:buster_claw, :google_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    request_options =
      [
        url: @token_endpoint,
        form: form,
        headers: [{"accept", "application/json"}],
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.post(request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:google_oauth_error, status, decode_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_body(body), do: body

  defp token_attrs(body, opts \\ [])

  defp token_attrs(body, opts) when is_map(body) do
    access_token = get_value(body, "access_token")

    if access_token in [nil, ""] do
      {:error, {:bad_token_response, body}}
    else
      attrs = %{
        "access_token" => access_token,
        "access_token_expires_at" => expires_at(get_value(body, "expires_in"))
      }

      attrs =
        body
        |> get_value("scope")
        |> put_if_present(attrs, "scopes")

      attrs =
        if Keyword.get(opts, :keep_refresh_token?, true) do
          body
          |> get_value("refresh_token")
          |> put_if_present(attrs, "refresh_token")
        else
          attrs
        end

      {:ok, attrs}
    end
  end

  defp token_attrs(body, _opts), do: {:error, {:bad_token_response, body}}

  defp get_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp put_if_present(value, attrs, _key) when value in [nil, ""], do: attrs
  defp put_if_present(value, attrs, key), do: Map.put(attrs, key, value)

  defp expires_at(value) do
    seconds = parse_seconds(value) || 3600

    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp parse_seconds(value) when is_integer(value), do: value

  defp parse_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  defp parse_seconds(_value), do: nil
end
