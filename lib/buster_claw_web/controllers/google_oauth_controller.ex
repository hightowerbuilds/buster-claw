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
    case WebGoogleOAuth.verify_state(state) do
      {:ok, %{bundled: true} = state_data} ->
        bundled_callback(conn, code, state_data)

      {:ok, %{account_id: _} = state_data} ->
        account_callback(conn, code, state_data)

      {:ok, _other} ->
        oauth_response(conn, "Google Workspace connection failed.", "Unrecognized state.")

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

  # BYO / reconnect path: the state token names an existing account.
  defp account_callback(conn, code, %{account_id: account_id, redirect_uri: redirect_uri} = state) do
    with {:ok, account} <- fetch_account(account_id),
         {:ok, account} <-
           OAuth.exchange_code(account, code, redirect_uri,
             code_verifier: Map.get(state, :code_verifier)
           ) do
      run_self_test(account)

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

  # One-click bundled path: no account row exists yet. Exchange the code with
  # the bundled client, learn the address from the Gmail profile, then upsert —
  # a brand-new address creates the account; a known one gets fresh tokens and
  # is moved onto the bundled client (the tokens were just minted by it, so the
  # stored client pair must match for refresh to work).
  defp bundled_callback(conn, code, %{redirect_uri: redirect_uri} = state) do
    with {:ok, client} <- fetch_bundled_client(),
         {:ok, attrs} <-
           OAuth.exchange_code_raw(client.client_id, client.client_secret, code, redirect_uri,
             code_verifier: Map.get(state, :code_verifier)
           ),
         {:ok, email} <- OAuth.fetch_profile_email(attrs["access_token"]),
         {:ok, account} <-
           Google.upsert_account(
             attrs
             |> Map.merge(%{
               "email" => email,
               "client_id" => client.client_id,
               "client_secret" => client.client_secret,
               "enabled" => true
             })
             |> Map.put_new("scopes", OAuth.default_scope_string())
             |> Map.put_new("default_query", "newer_than:7d")
           ) do
      # Same courtesy as the Setup wizard's BYO path: trust the user's own
      # address so an email to yourself produces a real Dispatch item.
      trust_own_address(account)
      # A fresh connect revives a dead session (the upsert path doesn't go
      # through exchange_code/4, which clears this for BYO reconnects).
      Google.clear_reconnect_needed(account)
      run_self_test(account)

      oauth_response(
        conn,
        "Google Workspace is connected.",
        "#{account.email} is ready in Buster Claw."
      )
    else
      {:error, reason} ->
        oauth_response(
          conn,
          "Google Workspace connection failed.",
          ErrorFormatter.format(reason)
        )
    end
  end

  defp trust_own_address(%{email: email}) when is_binary(email) and email != "" do
    BusterClaw.TrustedSenders.add_entry(email)
  rescue
    _ -> :ok
  end

  defp trust_own_address(_account), do: :ok

  # Post-connect self-test (Phase 3): answer "did it actually work?" with
  # per-surface checks the GWS panel renders. Async so the callback page (the
  # tab the user is staring at) never waits on three API calls; :sync exists
  # for tests, :disabled for suites that don't care.
  defp run_self_test(account) do
    case Application.get_env(:buster_claw, :google_self_test, :async) do
      :disabled ->
        :ok

      :sync ->
        BusterClaw.Google.SelfTest.run(account)
        :ok

      _async ->
        Task.Supervisor.start_child(BusterClaw.SwarmTaskSupervisor, fn ->
          BusterClaw.Google.SelfTest.run(account)
        end)

        :ok
    end
  end

  defp fetch_bundled_client do
    case BusterClaw.Google.BundledClient.get() do
      nil -> {:error, :bundled_client_unavailable}
      client -> {:ok, client}
    end
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
          <a href="/settings">Open Buster Claw</a>
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
