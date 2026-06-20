defmodule BusterClaw.Google.PeopleTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.People

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "list returns contact summaries with personFields" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v1/people/me/connections"
      assert conn.query_params["personFields"] =~ "names"

      Req.Test.json(conn, %{
        "connections" => [
          %{
            "resourceName" => "people/c1",
            "etag" => "etag-1",
            "names" => [%{"displayName" => "Ada Lovelace"}]
          }
        ],
        "nextPageToken" => "p2"
      })
    end)

    assert {:ok, %{contacts: [contact], next_page_token: "p2"}} =
             People.list(connected_account!(), req_options: @plug)

    assert contact.resource_name == "people/c1"
    assert contact.display_name == "Ada Lovelace"
  end

  test "search reads results' person objects" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v1/people:searchContacts"
      assert conn.query_params["query"] == "ada"

      Req.Test.json(conn, %{
        "results" => [%{"person" => %{"resourceName" => "people/c1", "etag" => "e"}}]
      })
    end)

    assert {:ok, %{contacts: [%{resource_name: "people/c1"}]}} =
             People.search(connected_account!(), "ada", req_options: @plug)
  end

  test "create posts a Person resource" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/people:createContact"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"names" => [%{"givenName" => "Ada"}]}
      Req.Test.json(conn, %{"resourceName" => "people/c1", "etag" => "e"})
    end)

    assert {:ok, %{resource_name: "people/c1"}} =
             People.create(connected_account!(), %{"names" => [%{"givenName" => "Ada"}]},
               req_options: @plug
             )
  end

  test "update PATCHes with updatePersonFields and echoes the etag" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/v1/people/c1:updateContact"
      assert conn.query_params["updatePersonFields"] =~ "names"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["etag"] == "etag-1"
      assert decoded["names"] == [%{"givenName" => "Ada B"}]

      Req.Test.json(conn, %{"resourceName" => "people/c1", "etag" => "etag-2"})
    end)

    assert {:ok, %{resource_name: "people/c1", etag: "etag-2"}} =
             People.update(
               connected_account!(),
               "people/c1",
               %{"names" => [%{"givenName" => "Ada B"}]},
               "etag-1",
               req_options: @plug
             )
  end

  test "delete removes a contact" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/people/c1:deleteContact"
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert {:ok, %{resource_name: "people/c1", deleted: true}} =
             People.delete(connected_account!(), "people/c1", req_options: @plug)
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
