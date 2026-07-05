defmodule BusterClaw.Google.SelfTestTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Google
  alias BusterClaw.Google.SelfTest

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp connected_account! do
    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "refresh_token" => "refresh-token",
        "access_token" => "access-token",
        "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    account
  end

  defp req_opts, do: [req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]]

  test "run probes all surfaces, persists, and surfaces on the summary" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      case conn.request_path do
        "/gmail/v1/users/me/profile" ->
          Req.Test.json(conn, %{"emailAddress" => "me@example.com"})

        "/calendar/v3/users/me/calendarList" ->
          Req.Test.json(conn, %{"items" => []})

        "/drive/v3/about" ->
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"error" => %{"message" => "Drive API disabled"}})
      end
    end)

    account = connected_account!()

    assert %{mail: :ok, calendar: :ok, drive: {:error, message}} =
             SelfTest.run(account, req_opts())

    assert message =~ "HTTP 403"
    assert message =~ "Drive API disabled"

    assert %{at: at, results: results} = SelfTest.last(account.id)
    assert is_binary(at)
    assert results["mail"] == "ok"
    assert results["calendar"] == "ok"
    assert results["drive"] =~ "HTTP 403"
    assert SelfTest.healthy?(account.id) == false

    summary = Google.account_summary(Google.get_account!(account.id))
    assert summary.self_test.results["mail"] == "ok"
  end

  test "healthy? is true when every surface is ok, nil when never run" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    account = connected_account!()
    assert SelfTest.healthy?(account.id) == nil

    SelfTest.run(account, req_opts())
    assert SelfTest.healthy?(account.id) == true
  end

  test "clear drops the persisted result" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn -> Req.Test.json(conn, %{}) end)

    account = connected_account!()
    SelfTest.run(account, req_opts())
    assert SelfTest.last(account.id)

    SelfTest.clear(account.id)
    assert SelfTest.last(account.id) == nil
  end
end
