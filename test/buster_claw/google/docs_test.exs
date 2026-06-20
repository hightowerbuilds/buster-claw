defmodule BusterClaw.Google.DocsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Docs

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "get fetches a document" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v1/documents/doc-1"
      Req.Test.json(conn, %{"documentId" => "doc-1", "title" => "Notes"})
    end)

    assert {:ok, %{document_id: "doc-1", title: "Notes"}} =
             Docs.get(connected_account!(), "doc-1", req_options: @plug)
  end

  test "create posts a titled document" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/documents"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"title" => "Notes"}
      Req.Test.json(conn, %{"documentId" => "doc-1", "title" => "Notes"})
    end)

    assert {:ok, %{document_id: "doc-1"}} =
             Docs.create(connected_account!(), "Notes", req_options: @plug)
  end

  test "batch_update posts the request list" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/documents/doc-1:batchUpdate"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"requests" => [%{"insertText" => %{"text" => "hi"}}]}
      Req.Test.json(conn, %{"documentId" => "doc-1", "replies" => [%{}]})
    end)

    assert {:ok, %{"documentId" => "doc-1"}} =
             Docs.batch_update(
               connected_account!(),
               "doc-1",
               [%{"insertText" => %{"text" => "hi"}}],
               req_options: @plug
             )
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
