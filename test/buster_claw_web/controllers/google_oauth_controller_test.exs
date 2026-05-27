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
end
