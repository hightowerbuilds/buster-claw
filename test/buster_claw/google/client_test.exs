defmodule BusterClaw.Google.ClientTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Client

  @base "https://www.googleapis.com/drive/v3"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "patch_json issues a PATCH with a JSON body" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/drive/v3/files/file-1"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "renamed"}

      Req.Test.json(conn, %{"id" => "file-1", "name" => "renamed"})
    end)

    assert {:ok, %{"name" => "renamed"}} =
             Client.patch_json(
               connected_account!(),
               "files/file-1",
               %{"name" => "renamed"},
               base_url: @base,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "put_json issues a PUT with a JSON body" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PUT"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"values" => [["a", "b"]]}
      Req.Test.json(conn, %{"updatedCells" => 2})
    end)

    assert {:ok, %{"updatedCells" => 2}} =
             Client.put_json(
               connected_account!(),
               "spreadsheets/s/values/A1",
               %{"values" => [["a", "b"]]},
               base_url: "https://sheets.googleapis.com/v4",
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "delete tolerates an empty 204 body" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "DELETE"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, ""} =
             Client.delete(
               connected_account!(),
               "files/file-1",
               base_url: @base,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "get_json with decode: false returns the raw body untouched" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, ~s({"k":1}))
    end)

    assert {:ok, ~s({"k":1})} =
             Client.get_json(
               connected_account!(),
               "files/file-1",
               base_url: @base,
               decode: false,
               params: [{"alt", "media"}],
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "upload sends a multipart/related body with metadata and media" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "www.googleapis.com"
      assert conn.request_path == "/upload/drive/v3/files"
      assert conn.query_params["uploadType"] == "multipart"

      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "multipart/related; boundary="

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ ~s("name":"hello.txt")
      assert body =~ "file-bytes-here"

      Req.Test.json(conn, %{"id" => "uploaded-1", "name" => "hello.txt"})
    end)

    assert {:ok, %{"id" => "uploaded-1"}} =
             Client.upload(
               connected_account!(),
               "files",
               %{
                 metadata: %{"name" => "hello.txt"},
                 data: "file-bytes-here",
                 content_type: "text/plain"
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "refreshes the access token and retries once on a 401" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      if conn.request_path == "/token" do
        # Token refresh exchange.
        Req.Test.json(conn, %{"access_token" => "fresh-token", "expires_in" => 3600})
      else
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0 do
          Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"}))
        else
          [auth] = Plug.Conn.get_req_header(conn, "authorization")
          assert auth == "Bearer fresh-token"
          Req.Test.json(conn, %{"id" => "file-1"})
        end
      end
    end)

    assert {:ok, %{"id" => "file-1"}} =
             Client.get_json(
               connected_account!(),
               "files/file-1",
               base_url: @base,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "surfaces a distinct retryable error on 429 with Retry-After" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"message" => "Rate Limit Exceeded"}})
    end)

    assert {:error, {:google_api_rate_limited, 429, 30, body}} =
             Client.get_json(
               connected_account!(),
               "files/file-1",
               base_url: @base,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert body["error"]["message"] == "Rate Limit Exceeded"
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
end
