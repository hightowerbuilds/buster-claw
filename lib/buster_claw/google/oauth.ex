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

  @doc "A fresh PKCE code verifier (43-char URL-safe random string)."
  def generate_code_verifier do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "The S256 code challenge for a PKCE verifier."
  def code_challenge(verifier) when is_binary(verifier) do
    :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  # PKCE (`opts[:code_challenge]`) rides on top of the client secret rather
  # than replacing it: Google's Desktop-app clients require the (per Google,
  # non-confidential) secret at token exchange even with PKCE, and sending the
  # challenge is harmless for BYO web-type clients.
  def authorization_url(%Account{} = account, redirect_uri, state, opts \\ []) do
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

    params =
      case Keyword.get(opts, :code_challenge) do
        nil ->
          params

        challenge ->
          Map.merge(params, %{
            "code_challenge" => challenge,
            "code_challenge_method" => "S256"
          })
      end

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
             ]
             |> maybe_put_verifier(opts),
             opts
           ),
         {:ok, attrs} <- token_attrs(body),
         {:ok, updated} <- Google.update_account(account, attrs) do
      Google.clear_reconnect_needed(updated)
      {:ok, updated}
    end
  end

  defp maybe_put_verifier(form, opts) do
    case Keyword.get(opts, :code_verifier) do
      verifier when is_binary(verifier) and verifier != "" ->
        Keyword.put(form, :code_verifier, verifier)

      _ ->
        form
    end
  end

  @doc """
  Exchange an authorization code without a persisted account — the bundled
  one-click connect path, where the `Account` row is only created *after* the
  address is discovered. Returns `{:ok, attrs}` (the same map `exchange_code/4`
  persists: access/refresh tokens, expiry, scopes) or an error tuple.
  """
  def exchange_code_raw(client_id, client_secret, code, redirect_uri, opts \\ []) do
    with {:ok, body} <-
           request_token(
             [
               client_id: client_id,
               client_secret: client_secret,
               code: code,
               grant_type: "authorization_code",
               redirect_uri: redirect_uri
             ]
             |> maybe_put_verifier(opts),
             opts
           ) do
      token_attrs(body)
    end
  end

  @gmail_profile_endpoint "https://gmail.googleapis.com/gmail/v1/users/me/profile"

  @doc """
  Discover the connected address from a raw access token via the Gmail profile
  endpoint — already covered by the `mail.google.com` scope, so one-click
  connect needs no extra openid/userinfo scopes on the consent screen.
  Returns `{:ok, email}` or an error tuple.
  """
  def fetch_profile_email(access_token, opts \\ []) do
    req_options =
      []
      |> Keyword.merge(Application.get_env(:buster_claw, :google_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    request_options =
      [
        url: @gmail_profile_endpoint,
        auth: {:bearer, access_token},
        headers: [{"accept", "application/json"}],
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.get(request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case body |> decode_body() |> profile_email() do
          nil -> {:error, {:bad_profile_response, decode_body(body)}}
          email -> {:ok, email}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:google_api_error, status, decode_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp profile_email(%{} = body) do
    case get_value(body, "emailAddress") do
      email when is_binary(email) and email != "" -> email
      _ -> nil
    end
  end

  defp profile_email(_body), do: nil

  def refresh_access_token(%Account{} = account, opts \\ []) do
    result =
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

    # Token-health hook (Phase 4): a refresh outcome is the single truth about
    # whether the Google session is alive. invalid_grant = the refresh token
    # itself is dead (revoked, or weekly Testing-status expiry during the
    # beta) — only a manual reconnect revives it, so flag it loudly-but-once.
    case result do
      {:ok, updated} ->
        Google.clear_reconnect_needed(updated)
        {:ok, updated}

      {:error, {:google_oauth_error, _status, %{"error" => "invalid_grant"}}} ->
        Google.mark_reconnect_needed(account)
        result

      _ ->
        result
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

  # Token responses normally arrive JSON-decoded with string keys; the atom
  # fallback exists for atom-keyed maps handed in by tests. Uses
  # to_existing_atom so a hostile/unexpected response body can never mint new
  # atoms (the atom table is not GC'd) — if the atom doesn't already exist,
  # no caller is using it as a key anyway.
  defp get_value(map, key) do
    case Map.get(map, key) do
      nil -> Map.get(map, String.to_existing_atom(key))
      value -> value
    end
  rescue
    ArgumentError -> nil
  end

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
