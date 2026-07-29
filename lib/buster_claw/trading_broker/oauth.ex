defmodule BusterClaw.TradingBroker.OAuth do
  @moduledoc """
  OAuth 2.1 + PKCE client for Robinhood's protected Trading MCP resource.

  Discovery is validated against an explicit HTTPS host allowlist before any
  advertised endpoint is called. Tokens are handed immediately to
  `BusterClaw.TradingBroker` for encrypted persistence and are never logged.
  """

  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingBroker.Connection

  @resource "https://agent.robinhood.com/mcp/trading"
  @resource_metadata "https://agent.robinhood.com/.well-known/oauth-protected-resource/mcp/trading"
  @scope "internal"
  @refresh_margin_seconds 60

  @allowed_endpoints %{
    authorization_endpoint: {"robinhood.com", "/oauth"},
    token_endpoint: {"api.robinhood.com", "/oauth2/token/"},
    registration_endpoint: {"agent.robinhood.com", "/oauth/trading/register"}
  }

  def resource, do: @resource
  def scope, do: @scope

  @doc "A fresh PKCE verifier suitable for S256."
  def generate_code_verifier do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def code_challenge(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc "Discover and strictly validate Robinhood's OAuth endpoints."
  def discover(opts \\ []) do
    with {:ok, resource_metadata} <- get_json(@resource_metadata, opts),
         :ok <- validate_resource_metadata(resource_metadata),
         [authorization_server] <- value(resource_metadata, "authorization_servers"),
         {:ok, metadata_url} <- authorization_metadata_url(authorization_server),
         {:ok, authorization_metadata} <- get_json(metadata_url, opts),
         {:ok, normalized} <-
           validate_authorization_metadata(authorization_metadata, authorization_server) do
      {:ok, normalized}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_broker_oauth_metadata}
    end
  end

  @doc "Register BusterClaw as a public native client with the discovered server."
  def register_client(redirect_uri, opts \\ []) when is_binary(redirect_uri) do
    with :ok <- validate_redirect_uri(redirect_uri),
         {:ok, metadata} <- discover(opts),
         body = %{
           "application_type" => "native",
           "client_name" => "Buster Claw",
           "grant_types" => ["authorization_code", "refresh_token"],
           "redirect_uris" => [redirect_uri],
           "response_types" => ["code"],
           "scope" => @scope,
           "token_endpoint_auth_method" => "none"
         },
         {:ok, response} <- post_json(metadata.registration_endpoint, body, opts),
         client_id when is_binary(client_id) and client_id != "" <- value(response, "client_id"),
         {:ok, connection} <- TradingBroker.put_client_id(client_id) do
      {:ok, connection}
    else
      nil -> {:error, :missing_broker_client_id}
      "" -> {:error, :missing_broker_client_id}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_broker_registration}
    end
  end

  @doc "Build the authorization URL for a registered connection."
  def authorization_url(connection, redirect_uri, state, verifier, opts \\ [])

  def authorization_url(
        %Connection{client_id: client_id},
        redirect_uri,
        state,
        verifier,
        opts
      )
      when is_binary(client_id) and client_id != "" and is_binary(state) and
             is_binary(verifier) do
    with :ok <- validate_redirect_uri(redirect_uri),
         {:ok, metadata} <- discover(opts) do
      params = %{
        "client_id" => client_id,
        "code_challenge" => code_challenge(verifier),
        "code_challenge_method" => "S256",
        "redirect_uri" => redirect_uri,
        "resource" => @resource,
        "response_type" => "code",
        "scope" => @scope,
        "state" => state
      }

      {:ok, metadata.authorization_endpoint <> "?" <> URI.encode_query(params)}
    end
  end

  def authorization_url(_connection, _redirect_uri, _state, _verifier, _opts),
    do: {:error, :broker_client_not_registered}

  @doc "Exchange an authorization code and persist encrypted tokens."
  def exchange_code(%Connection{client_id: client_id}, code, redirect_uri, verifier, opts \\ [])
      when is_binary(client_id) and is_binary(code) and code != "" and is_binary(verifier) do
    with :ok <- validate_redirect_uri(redirect_uri),
         {:ok, metadata} <- discover(opts),
         {:ok, response} <-
           post_form(
             metadata.token_endpoint,
             [
               client_id: client_id,
               code: code,
               code_verifier: verifier,
               grant_type: "authorization_code",
               redirect_uri: redirect_uri,
               resource: @resource
             ],
             opts
           ) do
      TradingBroker.put_tokens(response)
    end
  end

  @doc "Return a current access token, refreshing and rotating tokens as needed."
  def access_token(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case TradingBroker.connection() do
      %Connection{} = connection ->
        cond do
          current_token?(connection, now) ->
            {:ok, connection.access_token}

          is_binary(connection.refresh_token) and connection.refresh_token != "" ->
            refresh(connection, opts)

          true ->
            {:error, :broker_reconnect_required}
        end

      nil ->
        {:error, :broker_not_connected}
    end
  end

  def refresh(connection, opts \\ [])

  def refresh(%Connection{client_id: client_id, refresh_token: refresh_token}, opts)
      when is_binary(client_id) and is_binary(refresh_token) and refresh_token != "" do
    with {:ok, metadata} <- discover(opts),
         {:ok, response} <-
           post_form(
             metadata.token_endpoint,
             [
               client_id: client_id,
               grant_type: "refresh_token",
               refresh_token: refresh_token,
               resource: @resource,
               scope: @scope
             ],
             opts
           ),
         {:ok, connection} <-
           TradingBroker.put_tokens(response, Keyword.get(opts, :now, DateTime.utc_now())) do
      {:ok, connection.access_token}
    else
      {:error, {:broker_oauth_http, status, error}}
      when status in [400, 401] and error in ["invalid_grant", "invalid_token"] ->
        _ = TradingBroker.mark_checked("reconnect_required", :oauth_refresh_rejected)
        {:error, :broker_reconnect_required}

      {:error, _reason} = error ->
        error
    end
  end

  def refresh(_connection, _opts), do: {:error, :broker_reconnect_required}

  defp current_token?(
         %Connection{
           access_token: access_token,
           access_token_expires_at: %DateTime{} = expires_at
         },
         now
       )
       when is_binary(access_token) and access_token != "" do
    DateTime.compare(expires_at, DateTime.add(now, @refresh_margin_seconds, :second)) == :gt
  end

  defp current_token?(_connection, _now), do: false

  defp validate_resource_metadata(metadata) do
    cond do
      value(metadata, "resource") != @resource ->
        {:error, :broker_resource_mismatch}

      @scope not in List.wrap(value(metadata, "scopes_supported")) ->
        {:error, :broker_scope_unavailable}

      true ->
        :ok
    end
  end

  defp validate_authorization_metadata(metadata, authorization_server) do
    with true <- value(metadata, "issuer") == authorization_server,
         true <- "S256" in List.wrap(value(metadata, "code_challenge_methods_supported")),
         true <- "authorization_code" in List.wrap(value(metadata, "grant_types_supported")),
         true <- "refresh_token" in List.wrap(value(metadata, "grant_types_supported")),
         true <- "none" in List.wrap(value(metadata, "token_endpoint_auth_methods_supported")),
         {:ok, authorization_endpoint} <-
           validate_endpoint(metadata, :authorization_endpoint),
         {:ok, token_endpoint} <- validate_endpoint(metadata, :token_endpoint),
         {:ok, registration_endpoint} <- validate_endpoint(metadata, :registration_endpoint) do
      {:ok,
       %{
         authorization_endpoint: authorization_endpoint,
         token_endpoint: token_endpoint,
         registration_endpoint: registration_endpoint
       }}
    else
      _other -> {:error, :invalid_broker_authorization_metadata}
    end
  end

  defp validate_endpoint(metadata, key) do
    url = value(metadata, Atom.to_string(key))
    expected = Map.fetch!(@allowed_endpoints, key)

    case is_binary(url) && URI.parse(url) do
      %URI{scheme: "https", host: host, path: path, query: nil, fragment: nil}
      when {host, path} == expected ->
        {:ok, url}

      _other ->
        {:error, :untrusted_broker_oauth_endpoint}
    end
  end

  defp authorization_metadata_url(server) when is_binary(server) do
    case URI.parse(server) do
      %URI{scheme: "https", host: "agent.robinhood.com", path: path}
      when is_binary(path) ->
        {:ok, "https://agent.robinhood.com/.well-known/oauth-authorization-server#{path}"}

      _other ->
        {:error, :untrusted_broker_authorization_server}
    end
  end

  defp authorization_metadata_url(_server),
    do: {:error, :untrusted_broker_authorization_server}

  defp validate_redirect_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: "http", host: host, query: nil, fragment: nil}
      when host in ["127.0.0.1", "localhost"] ->
        :ok

      %URI{scheme: "https", host: host, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, :invalid_broker_redirect_uri}
    end
  end

  defp get_json(url, opts), do: request(:get, url, [], opts)
  defp post_json(url, body, opts), do: request(:post, url, [json: body], opts)
  defp post_form(url, form, opts), do: request(:post, url, [form: form], opts)

  defp request(method, url, request_options, opts) do
    req_options =
      []
      |> Keyword.merge(Application.get_env(:buster_claw, :trading_broker_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    options =
      [
        method: method,
        url: url,
        headers: [{"accept", "application/json"}],
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(request_options)
      |> Keyword.merge(req_options)

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_map(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:broker_oauth_http, status, oauth_error(body)}}

      {:error, _reason} ->
        {:error, :broker_oauth_unreachable}
    end
  end

  defp decode_map(body) when is_map(body), do: {:ok, body}

  defp decode_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, :invalid_broker_oauth_response}
    end
  end

  defp decode_map(_body), do: {:error, :invalid_broker_oauth_response}

  defp oauth_error(body) when is_map(body) do
    case value(body, "error") do
      error when is_binary(error) -> String.slice(error, 0, 100)
      _other -> "oauth_error"
    end
  end

  defp oauth_error(_body), do: "oauth_error"

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      try do
        Map.get(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end
  end
end
