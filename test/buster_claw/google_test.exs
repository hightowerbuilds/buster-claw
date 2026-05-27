defmodule BusterClaw.GoogleTest do
  use BusterClaw.DataCase

  alias BusterClaw.Google
  alias BusterClaw.Google.Account
  alias BusterClaw.Google.OAuth
  alias BusterClaw.Google.Vault

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "vault" do
    test "encrypts and decrypts credential values" do
      assert {:ok, encrypted} = Vault.encrypt("client-secret")
      refute encrypted == "client-secret"
      assert {:ok, "client-secret"} = Vault.decrypt(encrypted)
    end

    test "rejects malformed ciphertext" do
      assert {:error, :invalid_ciphertext} = Vault.decrypt(<<1, 2, 3>>)
    end
  end

  describe "accounts" do
    test "creates accounts with encrypted credentials and safe summaries" do
      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "  me@example.com  ",
                 "client_id" => "  client-id  ",
                 "client_secret" => "client-secret",
                 "refresh_token" => "refresh-token",
                 "access_token" => "access-token",
                 "scopes" => "gmail.readonly  gmail.compose gmail.readonly",
                 "default_query" => "newer_than:7d"
               })

      assert account.email == "me@example.com"
      assert account.client_id == "client-id"
      assert account.client_secret == nil
      assert account.refresh_token == nil
      assert account.access_token == nil
      assert account.scopes == "gmail.readonly gmail.compose"
      assert is_binary(account.client_secret_enc)
      assert is_binary(account.refresh_token_enc)
      assert is_binary(account.access_token_enc)

      assert {:ok, "client-secret"} = Account.decrypt(account, :client_secret)
      assert {:ok, "refresh-token"} = Account.decrypt(account, :refresh_token)
      assert {:ok, "access-token"} = Account.decrypt(account, :access_token)

      assert [summary] = Google.list_account_summaries()
      assert summary.email == "me@example.com"
      assert summary.client_id == "client-id"
      assert summary.has_client_secret
      assert summary.has_refresh_token
      assert summary.has_access_token
      refute Map.has_key?(summary, :client_secret)
      refute Map.has_key?(summary, :refresh_token)
      refute Map.has_key?(summary, :access_token)
    end

    test "updates credential fields without exposing plaintext" do
      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "me@example.com",
                 "client_id" => "client-id",
                 "refresh_token" => "old-refresh"
               })

      assert {:ok, updated} =
               Google.update_account(account, %{
                 "refresh_token" => "new-refresh",
                 "enabled" => false
               })

      assert updated.enabled == false
      assert updated.refresh_token == nil
      assert {:ok, "new-refresh"} = Account.decrypt(updated, :refresh_token)
    end
  end

  describe "oauth" do
    test "builds a desktop authorization URL" do
      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "me@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret",
                 "scopes" => OAuth.default_scope_string()
               })

      url =
        OAuth.authorization_url(account, "http://127.0.0.1:4000/google/oauth/callback", "state")

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.host == "accounts.google.com"
      assert params["client_id"] == "client-id"
      assert params["redirect_uri"] == "http://127.0.0.1:4000/google/oauth/callback"
      assert params["response_type"] == "code"
      assert params["access_type"] == "offline"
      assert params["prompt"] == "consent"
      assert params["scope"] =~ "gmail.readonly"
      assert params["scope"] =~ "gmail.compose"
      assert params["state"] == "state"
    end

    test "authorization URL includes new default scopes for older connected accounts" do
      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "me@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret",
                 "scopes" => "https://www.googleapis.com/auth/gmail.readonly"
               })

      url =
        OAuth.authorization_url(account, "http://127.0.0.1:4000/google/oauth/callback", "state")

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["scope"] =~ "gmail.readonly"
      assert params["scope"] =~ "gmail.compose"
      assert params["scope"] =~ "calendar.events.readonly"
    end

    test "exchanges a callback code and stores encrypted tokens" do
      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert body =~ "grant_type=authorization_code"
        assert body =~ "code=callback-code"
        assert body =~ "client_id=client-id"

        Req.Test.json(conn, %{
          "access_token" => "access-token",
          "expires_in" => 3600,
          "refresh_token" => "refresh-token",
          "scope" => OAuth.default_scope_string(),
          "token_type" => "Bearer"
        })
      end)

      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "me@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret"
               })

      assert {:ok, updated} =
               OAuth.exchange_code(
                 account,
                 "callback-code",
                 "http://127.0.0.1:4000/google/oauth/callback",
                 req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
               )

      assert updated.access_token == nil
      assert updated.refresh_token == nil
      assert is_binary(updated.access_token_enc)
      assert is_binary(updated.refresh_token_enc)
      assert {:ok, "access-token"} = Account.decrypt(updated, :access_token)
      assert {:ok, "refresh-token"} = Account.decrypt(updated, :refresh_token)
      assert %DateTime{} = updated.access_token_expires_at
    end

    test "returns Google OAuth error details when token exchange fails" do
      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client", "error_description" => "Unauthorized"})
      end)

      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "me@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret"
               })

      assert {:error,
              {:google_oauth_error, 401,
               %{"error" => "invalid_client", "error_description" => "Unauthorized"}}} =
               OAuth.exchange_code(
                 account,
                 "callback-code",
                 "http://127.0.0.1:4000/google/oauth/callback",
                 req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
               )
    end
  end
end
