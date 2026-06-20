defmodule BusterClaw.Google.SheetsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Sheets

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "get_values reads a range" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v4/spreadsheets/s-1/values/Sheet1%21A1%3AB2"
      Req.Test.json(conn, %{"range" => "Sheet1!A1:B2", "values" => [["a", "b"]]})
    end)

    assert {:ok, %{range: "Sheet1!A1:B2", values: [["a", "b"]]}} =
             Sheets.get_values(connected_account!(), "s-1", "Sheet1!A1:B2", req_options: @plug)
  end

  test "update_values PUTs with valueInputOption USER_ENTERED" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v4/spreadsheets/s-1/values/A1"
      assert conn.query_params["valueInputOption"] == "USER_ENTERED"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"range" => "A1", "values" => [["x"]]}

      Req.Test.json(conn, %{"updatedCells" => 1})
    end)

    assert {:ok, %{"updatedCells" => 1}} =
             Sheets.update_values(connected_account!(), "s-1", "A1", [["x"]], req_options: @plug)
  end

  test "append_values POSTs to the :append endpoint" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v4/spreadsheets/s-1/values/A1:append"
      assert conn.query_params["valueInputOption"] == "USER_ENTERED"
      Req.Test.json(conn, %{"updates" => %{"updatedRows" => 1}})
    end)

    assert {:ok, %{"updates" => %{"updatedRows" => 1}}} =
             Sheets.append_values(connected_account!(), "s-1", "A1", [["x"]], req_options: @plug)
  end

  test "clear_values POSTs to the :clear endpoint" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v4/spreadsheets/s-1/values/A1%3AB2:clear"
      Req.Test.json(conn, %{"clearedRange" => "A1:B2"})
    end)

    assert {:ok, %{"clearedRange" => "A1:B2"}} =
             Sheets.clear_values(connected_account!(), "s-1", "A1:B2", req_options: @plug)
  end

  test "create posts a titled spreadsheet" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/v4/spreadsheets"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"properties" => %{"title" => "Budget"}}
      Req.Test.json(conn, %{"spreadsheetId" => "s-1", "properties" => %{"title" => "Budget"}})
    end)

    assert {:ok, %{spreadsheet_id: "s-1", title: "Budget"}} =
             Sheets.create(connected_account!(), "Budget", req_options: @plug)
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
