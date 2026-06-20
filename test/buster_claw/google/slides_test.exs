defmodule BusterClaw.Google.SlidesTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Slides

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "get fetches a presentation and counts slides" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v1/presentations/p-1"
      Req.Test.json(conn, %{"presentationId" => "p-1", "title" => "Deck", "slides" => [%{}, %{}]})
    end)

    assert {:ok, %{presentation_id: "p-1", title: "Deck", slide_count: 2}} =
             Slides.get(connected_account!(), "p-1", req_options: @plug)
  end

  test "create posts a titled presentation" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v1/presentations"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"title" => "Deck"}
      Req.Test.json(conn, %{"presentationId" => "p-1", "title" => "Deck"})
    end)

    assert {:ok, %{presentation_id: "p-1"}} =
             Slides.create(connected_account!(), "Deck", req_options: @plug)
  end

  test "batch_update posts the request list" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v1/presentations/p-1:batchUpdate"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"requests" => [%{"createSlide" => %{}}]}
      Req.Test.json(conn, %{"presentationId" => "p-1", "replies" => [%{}]})
    end)

    assert {:ok, %{"presentationId" => "p-1"}} =
             Slides.batch_update(
               connected_account!(),
               "p-1",
               [%{"createSlide" => %{}}],
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
