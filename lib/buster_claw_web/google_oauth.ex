defmodule BusterClawWeb.GoogleOAuth do
  @moduledoc "Web-facing helpers for Google OAuth state and redirect URLs."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.OAuth

  @state_salt "google-oauth-state-v1"
  @max_age_seconds 10 * 60

  def authorization_url(%Account{} = account) do
    redirect_uri = callback_url()

    state =
      Phoenix.Token.sign(BusterClawWeb.Endpoint, @state_salt, %{
        account_id: account.id,
        nonce: nonce(),
        redirect_uri: redirect_uri
      })

    OAuth.authorization_url(account, redirect_uri, state)
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
