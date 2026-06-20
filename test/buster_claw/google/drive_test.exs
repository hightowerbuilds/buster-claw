defmodule BusterClaw.Google.DriveTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Drive

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "list returns file summaries and the page token" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/drive/v3/files"
      assert conn.query_params["q"] == "name contains 'report'"

      Req.Test.json(conn, %{
        "files" => [%{"id" => "f-1", "name" => "report.pdf", "mimeType" => "application/pdf"}],
        "nextPageToken" => "next-1"
      })
    end)

    assert {:ok, %{files: [%{id: "f-1", name: "report.pdf"}], next_page_token: "next-1"}} =
             Drive.list(connected_account!(), q: "name contains 'report'", req_options: @plug)
  end

  test "download returns raw bytes via alt=media without JSON decoding" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/drive/v3/files/f-1"
      assert conn.query_params["alt"] == "media"

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.send_resp(200, <<1, 2, 3, 4>>)
    end)

    assert {:ok, <<1, 2, 3, 4>>} =
             Drive.download(connected_account!(), "f-1", req_options: @plug)
  end

  test "upload sends a multipart/related body with metadata and media" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "www.googleapis.com"
      assert conn.request_path == "/upload/drive/v3/files"
      assert conn.query_params["uploadType"] == "multipart"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ ~s("name":"notes.txt")
      assert body =~ ~s("parents":["parent-1"])
      assert body =~ "the file body"

      Req.Test.json(conn, %{"id" => "uploaded-1", "name" => "notes.txt"})
    end)

    assert {:ok, %{id: "uploaded-1", name: "notes.txt"}} =
             Drive.upload(
               connected_account!(),
               %{
                 "name" => "notes.txt",
                 "data" => "the file body",
                 "content_type" => "text/plain",
                 "parent_id" => "parent-1"
               },
               req_options: @plug
             )
  end

  test "update_metadata moves a file via addParents/removeParents query params" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/drive/v3/files/f-1"
      assert conn.query_params["addParents"] == "new-parent"
      assert conn.query_params["removeParents"] == "old-parent"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "renamed.txt"}

      Req.Test.json(conn, %{"id" => "f-1", "name" => "renamed.txt", "parents" => ["new-parent"]})
    end)

    assert {:ok, %{id: "f-1", name: "renamed.txt"}} =
             Drive.update_metadata(
               connected_account!(),
               "f-1",
               %{"name" => "renamed.txt"},
               add_parents: "new-parent",
               remove_parents: "old-parent",
               req_options: @plug
             )
  end

  test "share grants a permission" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/drive/v3/files/f-1/permissions"
      assert conn.query_params["sendNotificationEmail"] == "false"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"role" => "reader", "type" => "anyone"}

      Req.Test.json(conn, %{"id" => "perm-1", "role" => "reader", "type" => "anyone"})
    end)

    assert {:ok, %{id: "perm-1", role: "reader", type: "anyone"}} =
             Drive.share(
               connected_account!(),
               "f-1",
               %{"role" => "reader", "type" => "anyone"},
               req_options: @plug
             )
  end

  test "delete removes a file" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/drive/v3/files/f-1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, %{id: "f-1", deleted: true}} =
             Drive.delete(connected_account!(), "f-1", req_options: @plug)
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
