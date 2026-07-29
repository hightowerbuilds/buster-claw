defmodule BusterClawWeb.TradingBrokerOAuthController do
  use BusterClawWeb, :controller

  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingBroker.MCPClient
  alias BusterClaw.TradingBroker.OAuth
  alias BusterClawWeb.TradingBrokerOAuth

  def callback(conn, %{"error" => error}) do
    oauth_response(conn, "Robinhood connection was not completed.", safe_oauth_error(error))
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, state_data} <- TradingBrokerOAuth.verify_state(state),
         %{id: id, client_id: client_id} = connection <- TradingBroker.connection(),
         true <- id == state_data.connection_id,
         true <- client_id == state_data.client_id,
         true <- state_data.redirect_uri == TradingBrokerOAuth.callback_url(),
         {:ok, _connection} <-
           OAuth.exchange_code(
             connection,
             code,
             state_data.redirect_uri,
             state_data.code_verifier
           ),
         {:ok, health} <- MCPClient.health() do
      account_note =
        if health.agentic_account,
          do: "Your Agentic account was discovered and is ready for structured reviews.",
          else: "Connected, but no write-enabled Agentic account was discovered."

      oauth_response(conn, "Robinhood is connected directly.", account_note)
    else
      false ->
        oauth_response(conn, "Robinhood connection failed.", "OAuth state did not match.")

      nil ->
        oauth_response(conn, "Robinhood connection failed.", "Connection state was not found.")

      {:error, reason} ->
        oauth_response(conn, "Robinhood connection failed.", error_message(reason))
    end
  end

  def callback(conn, _params) do
    oauth_response(conn, "Robinhood connection failed.", "Missing authorization code.")
  end

  defp error_message(:required_broker_tools_missing),
    do: "Robinhood connected, but the required account and review tools were not advertised."

  defp error_message(:broker_reconnect_required),
    do: "Robinhood rejected the session. Reconnect from the Trading tab."

  defp error_message(:invalid_broker_accounts),
    do: "Robinhood connected, but returned an unsupported account payload."

  defp error_message(_reason),
    do: "The direct Robinhood connection could not be verified. Try connecting again."

  defp safe_oauth_error(error) when is_binary(error) do
    case error do
      "access_denied" -> "Access was denied."
      "temporarily_unavailable" -> "Robinhood authorization is temporarily unavailable."
      _other -> "Robinhood returned an OAuth error."
    end
  end

  defp safe_oauth_error(_error), do: "Robinhood returned an OAuth error."

  defp oauth_response(conn, title, message) do
    title = escape_html(title)
    message = escape_html(message)

    html(conn, """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{title}</title>
        <style>
          body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0b0d0c; color: #f5f5f0; }
          main { width: min(90vw, 36rem); border: 2px solid #3a403c; background: #141815; padding: 2rem; box-shadow: 8px 8px 0 #232924; }
          h1 { margin: 0; font-size: 1.45rem; text-transform: uppercase; letter-spacing: .04em; }
          p { color: #b6bdb8; line-height: 1.6; }
          a { display: inline-flex; margin-top: 1rem; color: #0b0d0c; background: #b8f35a; padding: .75rem 1rem; text-decoration: none; font-weight: 800; text-transform: uppercase; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{title}</h1>
          <p>#{message}</p>
          <a href="/trading">Return to Trading</a>
        </main>
      </body>
    </html>
    """)
  end

  defp escape_html(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
