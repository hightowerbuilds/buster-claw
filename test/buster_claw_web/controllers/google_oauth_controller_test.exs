defmodule BusterClawWeb.GoogleOAuthControllerTest do
  use BusterClawWeb.ConnCase

  alias BusterClaw.Google
  alias BusterClaw.Google.Account
  alias BusterClawWeb.GoogleOAuth

  setup do
    Req.Test.verify_on_exit!()

    previous = Application.get_env(:buster_claw, :google_req_options)

    Application.put_env(:buster_claw, :google_req_options,
      plug: {Req.Test, BusterClaw.GoogleHTTP}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :google_req_options, previous)
      else
        Application.delete_env(:buster_claw, :google_req_options)
      end
    end)

    :ok
  end

  test "callback verifies state and stores returned tokens", %{conn: conn} do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "access-token",
        "expires_in" => 3600,
        "refresh_token" => "refresh-token",
        "scope" => "https://www.googleapis.com/auth/gmail.readonly",
        "token_type" => "Bearer"
      })
    end)

    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret"
      })

    state =
      Phoenix.Token.sign(BusterClawWeb.Endpoint, "google-oauth-state-v1", %{
        account_id: account.id,
        nonce: "test",
        redirect_uri: GoogleOAuth.callback_url()
      })

    conn = get(conn, ~p"/google/oauth/callback", %{"code" => "callback-code", "state" => state})

    assert html_response(conn, 200) =~ "Google Workspace is connected"

    updated = Google.get_account!(account.id)
    assert is_binary(updated.access_token_enc)
    assert is_binary(updated.refresh_token_enc)
    assert {:ok, "access-token"} = Account.decrypt(updated, :access_token)
    assert {:ok, "refresh-token"} = Account.decrypt(updated, :refresh_token)
  end

  test "callback rejects bad state", %{conn: conn} do
    conn = get(conn, ~p"/google/oauth/callback", %{"code" => "callback-code", "state" => "bad"})

    assert html_response(conn, 200) =~ "Google Workspace connection failed"
  end

  describe "bundled one-click connect" do
    setup do
      previous = Application.get_env(:buster_claw, :google_bundled_client)

      Application.put_env(:buster_claw, :google_bundled_client, %{
        client_id: "bundled-id",
        client_secret: "bundled-secret"
      })

      BusterClaw.Google.BundledClient.reset()

      on_exit(fn ->
        if previous do
          Application.put_env(:buster_claw, :google_bundled_client, previous)
        else
          Application.delete_env(:buster_claw, :google_bundled_client)
        end

        BusterClaw.Google.BundledClient.reset()
      end)

      :ok
    end

    test "authorization URL carries the bundled client, PKCE, and a bundled state" do
      assert {:ok, url} = GoogleOAuth.bundled_authorization_url()

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["client_id"] == "bundled-id"
      assert params["code_challenge_method"] == "S256"
      assert is_binary(params["code_challenge"])
      assert params["scope"] =~ "https://mail.google.com/"

      assert {:ok, state_data} = GoogleOAuth.verify_state(params["state"])
      assert state_data.bundled == true
      assert is_binary(state_data.code_verifier)
      assert state_data.redirect_uri == GoogleOAuth.callback_url()
    end

    test "callback creates the account from the discovered address", %{conn: conn} do
      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        case conn.host do
          "oauth2.googleapis.com" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body =~ "client_id=bundled-id"
            assert body =~ "client_secret=bundled-secret"
            assert body =~ "code=the-code"
            assert body =~ "code_verifier="

            Req.Test.json(conn, %{
              "access_token" => "bundled-access",
              "expires_in" => 3600,
              "refresh_token" => "bundled-refresh",
              "scope" => "https://mail.google.com/",
              "token_type" => "Bearer"
            })

          "gmail.googleapis.com" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bundled-access"]
            Req.Test.json(conn, %{"emailAddress" => "discovered@example.com"})
        end
      end)

      assert {:ok, url} = GoogleOAuth.bundled_authorization_url()
      %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      conn = get(conn, ~p"/google/oauth/callback", %{"code" => "the-code", "state" => state})

      assert html_response(conn, 200) =~ "discovered@example.com is ready"

      account = Google.get_account_by_email("discovered@example.com")
      assert account.client_id == "bundled-id"
      assert account.enabled
      assert {:ok, "bundled-access"} = Account.decrypt(account, :access_token)
      assert {:ok, "bundled-refresh"} = Account.decrypt(account, :refresh_token)
      assert BusterClaw.TrustedSenders.trusted?("discovered@example.com")
    end

    test "callback updates an existing account and moves it onto the bundled client", %{
      conn: conn
    } do
      {:ok, existing} =
        Google.create_account(%{
          "email" => "discovered@example.com",
          "client_id" => "old-byo-id",
          "client_secret" => "old-byo-secret"
        })

      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        case conn.host do
          "oauth2.googleapis.com" ->
            Req.Test.json(conn, %{
              "access_token" => "fresh-access",
              "expires_in" => 3600,
              "refresh_token" => "fresh-refresh",
              "token_type" => "Bearer"
            })

          "gmail.googleapis.com" ->
            Req.Test.json(conn, %{"emailAddress" => "discovered@example.com"})
        end
      end)

      assert {:ok, url} = GoogleOAuth.bundled_authorization_url()
      %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      conn = get(conn, ~p"/google/oauth/callback", %{"code" => "the-code", "state" => state})
      assert html_response(conn, 200) =~ "discovered@example.com is ready"

      updated = Google.get_account!(existing.id)
      assert updated.client_id == "bundled-id"
      assert {:ok, "fresh-access"} = Account.decrypt(updated, :access_token)
    end

    test "callback fails cleanly when the profile fetch fails", %{conn: conn} do
      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        case conn.host do
          "oauth2.googleapis.com" ->
            Req.Test.json(conn, %{
              "access_token" => "bundled-access",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            })

          "gmail.googleapis.com" ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error" => %{"message" => "insufficient scopes"}})
        end
      end)

      assert {:ok, url} = GoogleOAuth.bundled_authorization_url()
      %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      conn = get(conn, ~p"/google/oauth/callback", %{"code" => "the-code", "state" => state})

      assert html_response(conn, 200) =~ "Google Workspace connection failed"
      assert Google.get_account_by_email("discovered@example.com") == nil
    end
  end
end
