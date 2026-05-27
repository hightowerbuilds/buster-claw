defmodule BusterClawWeb.GoogleOAuthController do
  use BusterClawWeb, :controller

  alias BusterClaw.Google
  alias BusterClaw.Google.OAuth
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth, as: WebGoogleOAuth

  def callback(conn, %{"error" => error}) do
    message = Map.get(conn.params, "error_description", error)
    oauth_response(conn, "Google Workspace connection was not completed.", message)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, %{account_id: account_id, redirect_uri: redirect_uri}} <-
           WebGoogleOAuth.verify_state(state),
         {:ok, account} <- fetch_account(account_id),
         {:ok, account} <- OAuth.exchange_code(account, code, redirect_uri) do
      oauth_response(
        conn,
        "Google Workspace is connected.",
        "#{account.email} is ready in Buster Claw."
      )
    else
      {:error, :not_found} ->
        oauth_response(conn, "Google Workspace connection failed.", "Account was not found.")

      {:error, reason} ->
        oauth_response(
          conn,
          "Google Workspace connection failed.",
          ErrorFormatter.format(reason)
        )
    end
  end

  def callback(conn, _params) do
    oauth_response(conn, "Google Workspace connection failed.", "Missing authorization code.")
  end

  defp fetch_account(id) do
    {:ok, Google.get_account!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

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
          body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f7f7f5; color: #171717; }
          main { width: min(90vw, 34rem); border: 1px solid #deded8; border-radius: 8px; background: white; padding: 2rem; box-shadow: 0 12px 30px rgba(0,0,0,.08); }
          h1 { margin: 0; font-size: 1.5rem; }
          p { color: #555; line-height: 1.5; }
          a { display: inline-flex; margin-top: 1rem; color: white; background: #171717; border-radius: 6px; padding: .7rem 1rem; text-decoration: none; font-weight: 700; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{title}</h1>
          <p>#{message}</p>
          <a href="/gws">Open GWS</a>
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
