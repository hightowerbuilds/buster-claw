defmodule BusterClawWeb.GoogleOAuth do
  @moduledoc "Web-facing helpers for Google OAuth state and redirect URLs."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.BundledClient
  alias BusterClaw.Google.OAuth

  @state_salt "google-oauth-state-v1"
  @max_age_seconds 10 * 60

  def authorization_url(%Account{} = account) do
    redirect_uri = callback_url()
    # PKCE: the verifier rides inside the signed (tamper-proof, 10-minute)
    # state token so the callback can present it at token exchange.
    code_verifier = OAuth.generate_code_verifier()

    state =
      Phoenix.Token.sign(BusterClawWeb.Endpoint, @state_salt, %{
        account_id: account.id,
        nonce: nonce(),
        redirect_uri: redirect_uri,
        code_verifier: code_verifier
      })

    OAuth.authorization_url(account, redirect_uri, state,
      code_challenge: OAuth.code_challenge(code_verifier)
    )
  end

  @doc """
  Authorization URL for one-click connect via the bundled OAuth client. No
  `Account` row exists yet — the pending flow (bundled flag + PKCE verifier)
  travels entirely inside the signed state token, so an abandoned browser tab
  leaves nothing behind; the callback upserts the account only once Google has
  told us the address. Returns `{:ok, url}` or `{:error, :bundled_client_unavailable}`.
  """
  def bundled_authorization_url do
    case BundledClient.get() do
      nil ->
        {:error, :bundled_client_unavailable}

      client ->
        redirect_uri = callback_url()
        code_verifier = OAuth.generate_code_verifier()

        state =
          Phoenix.Token.sign(BusterClawWeb.Endpoint, @state_salt, %{
            bundled: true,
            nonce: nonce(),
            redirect_uri: redirect_uri,
            code_verifier: code_verifier
          })

        # A transient Account struct: authorization_url/4 only reads client_id
        # and scopes (nil scopes -> the full default set). Never persisted.
        account = %Account{client_id: client.client_id}

        {:ok,
         OAuth.authorization_url(account, redirect_uri, state,
           code_challenge: OAuth.code_challenge(code_verifier)
         )}
    end
  end

  def verify_state(state) do
    Phoenix.Token.verify(BusterClawWeb.Endpoint, @state_salt, state, max_age: @max_age_seconds)
  end

  def callback_url do
    case Application.get_env(:buster_claw, :google_redirect_base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        String.trim_trailing(base_url, "/") <> "/google/oauth/callback"

      _ ->
        port =
          BusterClawWeb.Endpoint.config(:http)
          |> Keyword.get(:port, 4000)

        "http://127.0.0.1:#{port}/google/oauth/callback"
    end
  end

  defp nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
