defmodule BusterClawWeb.ApiControllerTest do
  use BusterClawWeb.ConnCase

  alias BusterClaw.Commands

  @token "test-token-loopback-only"

  describe "GET /api/commands" do
    test "returns the catalog without auth", %{conn: conn} do
      conn = get(conn, ~p"/api/commands")
      assert %{"ok" => true, "commands" => commands} = json_response(conn, 200)
      assert is_list(commands)
      assert length(commands) > 0

      names = Enum.map(commands, & &1["name"])

      for representative <- ~w(runtime_status source_list provider_active chat_send web_search) do
        assert representative in names, "expected catalog to include #{representative}"
      end
    end
  end

  describe "POST /api/run — auth" do
    test "rejects requests without a token", %{conn: conn} do
      conn = post(conn, ~p"/api/run", %{"command" => "source_list"})
      assert %{"ok" => false, "error" => "unauthorized"} = json_response(conn, 401)
    end

    test "rejects requests with the wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong")
        |> post(~p"/api/run", %{"command" => "source_list"})

      assert json_response(conn, 401)
    end

    test "accepts requests with the right token", %{conn: conn} do
      conn = authed(conn) |> post(~p"/api/run", %{"command" => "source_list"})
      assert %{"ok" => true, "result" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/run — dispatch" do
    test "returns 404 for unknown commands", %{conn: conn} do
      conn = authed(conn) |> post(~p"/api/run", %{"command" => "no_such_cmd"})
      assert %{"ok" => false, "error" => "unknown_command"} = json_response(conn, 404)
    end

    test "returns 400 with no command", %{conn: conn} do
      conn = authed(conn) |> post(~p"/api/run", %{})
      assert %{"ok" => false} = json_response(conn, 400)
    end

    test "returns 422 + errors map on validation failure", %{conn: conn} do
      conn =
        authed(conn)
        |> post(~p"/api/run", %{"command" => "source_create", "args" => %{"url" => ""}})

      assert %{"ok" => false, "error" => "validation", "errors" => errors} =
               json_response(conn, 422)

      assert is_map(errors)
    end

    test "returns 404 with :not_found atom for missing resource", %{conn: conn} do
      conn =
        authed(conn)
        |> post(~p"/api/run", %{"command" => "source_get", "args" => %{"id" => 99_999}})

      assert %{"ok" => false, "error" => "not_found"} = json_response(conn, 404)
    end

    test "serializes datetimes as ISO 8601", %{conn: conn} do
      {:ok, source} =
        Commands.source_create(%{"url" => "https://example.com/iso", "type" => "rss"})

      conn =
        authed(conn)
        |> post(~p"/api/run", %{"command" => "source_get", "args" => %{"id" => source.id}})

      assert %{"ok" => true, "result" => result} = json_response(conn, 200)
      assert is_binary(result["inserted_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(result["inserted_at"])
    end

    test "round-trips create/delete via the API", %{conn: conn} do
      create_resp =
        authed(conn)
        |> post(~p"/api/run", %{
          "command" => "source_create",
          "args" => %{"url" => "https://example.com/api-rt", "type" => "rss"}
        })

      assert %{"ok" => true, "result" => %{"id" => id}} = json_response(create_resp, 200)

      delete_resp =
        authed(conn)
        |> post(~p"/api/run", %{
          "command" => "source_delete",
          "args" => %{"id" => id}
        })

      assert %{"ok" => true} = json_response(delete_resp, 200)
    end
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")
end
