defmodule BusterClawWeb.TradingBrokerOAuth do
  @moduledoc "Loopback callback and signed-state helpers for direct Robinhood MCP OAuth."

  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingBroker.OAuth
  alias BusterClaw.Vault

  @state_salt "trading-broker-oauth-state-v1"
  @max_age_seconds 10 * 60

  def authorization_url(opts \\ []) do
    redirect_uri = callback_url()
    verifier = OAuth.generate_code_verifier()

    with {:ok, connection} <- registered_connection(redirect_uri, opts),
         {:ok, encrypted_verifier} <- encrypt_verifier(verifier) do
      state =
        Phoenix.Token.sign(BusterClawWeb.Endpoint, @state_salt, %{
          connection_id: connection.id,
          client_id: connection.client_id,
          nonce: nonce(),
          redirect_uri: redirect_uri,
          encrypted_verifier: encrypted_verifier
        })

      OAuth.authorization_url(connection, redirect_uri, state, verifier, opts)
    end
  end

  def verify_state(state) when is_binary(state) do
    with {:ok, state_data} <-
           Phoenix.Token.verify(BusterClawWeb.Endpoint, @state_salt, state,
             max_age: @max_age_seconds
           ),
         {:ok, verifier} <- decrypt_verifier(state_data.encrypted_verifier) do
      {:ok,
       state_data
       |> Map.delete(:encrypted_verifier)
       |> Map.put(:code_verifier, verifier)}
    else
      _other -> {:error, :invalid}
    end
  end

  def verify_state(_state), do: {:error, :invalid}

  def callback_url do
    case Application.get_env(:buster_claw, :trading_broker_redirect_base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        String.trim_trailing(base_url, "/") <> "/trading/broker/oauth/callback"

      _other ->
        port =
          BusterClawWeb.Endpoint.config(:http)
          |> Keyword.get(:port, 4000)

        "http://127.0.0.1:#{port}/trading/broker/oauth/callback"
    end
  end

  defp registered_connection(redirect_uri, opts) do
    case TradingBroker.connection() do
      %{client_id: client_id} = connection when is_binary(client_id) and client_id != "" ->
        {:ok, connection}

      _other ->
        OAuth.register_client(redirect_uri, opts)
    end
  end

  defp nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp encrypt_verifier(verifier) do
    with {:ok, ciphertext} <- Vault.encrypt(verifier) do
      {:ok, Base.url_encode64(ciphertext, padding: false)}
    end
  end

  defp decrypt_verifier(encoded) when is_binary(encoded) do
    with {:ok, ciphertext} <- Base.url_decode64(encoded, padding: false),
         {:ok, verifier} <- Vault.decrypt(ciphertext),
         true <- is_binary(verifier) and verifier != "" do
      {:ok, verifier}
    else
      _other -> {:error, :invalid}
    end
  end

  defp decrypt_verifier(_encoded), do: {:error, :invalid}
end
