defmodule BusterClawWeb.ClinchControllerTest do
  @moduledoc """
  Clinch Phase 2: the write path, and the floor under it.

  The authorization tests are the point. `ApiAuth` alone would let the MCP token
  and the agent-untrusted token through — both are valid tokens — and neither
  should be able to touch credentials. That is not a hypothetical: the MCP token
  is handed to external agents, and the agent-untrusted token is handed to a
  headless run working content from the open internet.
  """
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.ApiToken
  alias BusterClaw.Clinch

  @value "Hunter2!x"

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp put_body(overrides \\ %{}) do
    Map.merge(%{"kind" => "sign_in", "name" => "acme-login", "value" => @value}, overrides)
  end

  describe "authorization — the floor, not a tier" do
    test "the full token may write", %{conn: conn} do
      conn = conn |> auth(ApiToken.value()) |> post(~p"/api/clinch", put_body())

      assert %{"ok" => true, "entry" => entry} = json_response(conn, 200)
      assert entry["name"] == "acme-login"
      assert {:ok, @value} = Clinch.resolve({:sign_in, "acme-login"})
    end

    test "the MCP token is forbidden, not merely tier-limited", %{conn: conn} do
      conn = conn |> auth(ApiToken.mcp_value()) |> post(~p"/api/clinch", put_body())

      assert %{"ok" => false, "error" => "forbidden"} = json_response(conn, 403)
      assert :error = Clinch.resolve({:sign_in, "acme-login"})
    end

    test "the agent-untrusted token is forbidden", %{conn: conn} do
      conn = conn |> auth(ApiToken.agent_value()) |> post(~p"/api/clinch", put_body())

      assert %{"ok" => false, "error" => "forbidden"} = json_response(conn, 403)
      assert :error = Clinch.resolve({:sign_in, "acme-login"})
    end

    test "no token at all is unauthorized", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch", put_body())

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "a wrong token is unauthorized", %{conn: conn} do
      conn = conn |> auth("not-a-real-token") |> post(~p"/api/clinch", put_body())

      assert json_response(conn, 401)
    end

    test "delete is behind the same floor", %{conn: conn} do
      assert {:ok, _} = Clinch.put({:sign_in, "acme-login"}, @value)

      conn =
        conn
        |> auth(ApiToken.mcp_value())
        |> delete(~p"/api/clinch", %{"kind" => "sign_in", "name" => "acme-login"})

      assert json_response(conn, 403)
      assert {:ok, @value} = Clinch.resolve({:sign_in, "acme-login"})
    end
  end

  describe "put" do
    setup %{conn: conn}, do: %{conn: auth(conn, ApiToken.value())}

    test "never echoes the value it just stored", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch", put_body(%{"note" => "the acme account"}))

      body = json_response(conn, 200)
      assert body["entry"]["note"] == "the acme account"
      refute Jason.encode!(body) =~ @value
    end

    test "replaces rather than duplicating", %{conn: conn} do
      assert %{"ok" => true} = conn |> post(~p"/api/clinch", put_body()) |> json_response(200)

      assert %{"ok" => true} =
               build_conn()
               |> auth(ApiToken.value())
               |> post(~p"/api/clinch", put_body(%{"value" => "second"}))
               |> json_response(200)

      assert {:ok, "second"} = Clinch.resolve({:sign_in, "acme-login"})
      assert [_one] = Clinch.list(:sign_in)
    end

    test "refuses an unmanaged kind", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch", put_body(%{"kind" => "device_key"}))
      assert %{"error" => "unmanaged_kind"} = json_response(conn, 422)
    end

    test "refuses an unknown kind without minting an atom for it", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch", put_body(%{"kind" => "totally_made_up_kind"}))

      assert %{"error" => "unknown_kind"} = json_response(conn, 422)

      # The point of matching against the declared enum rather than
      # `String.to_atom/1`: request input must not be able to grow the atom
      # table. If the controller had converted it, this would not raise.
      assert_raise ArgumentError, fn -> String.to_existing_atom("totally_made_up_kind") end
    end

    test "surfaces changeset errors for a bad name", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch", put_body(%{"name" => "Not Allowed!"}))

      assert %{"error" => "invalid", "details" => details} = json_response(conn, 422)
      assert details["name"]
    end

    test "refuses a missing value", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch", %{"kind" => "sign_in", "name" => "acme-login"})
      assert %{"error" => "missing_name_or_value"} = json_response(conn, 422)
    end
  end

  describe "delete" do
    setup %{conn: conn}, do: %{conn: auth(conn, ApiToken.value())}

    test "forgets a stored credential", %{conn: conn} do
      assert {:ok, _} = Clinch.put({:sign_in, "acme-login"}, @value)

      conn = delete(conn, ~p"/api/clinch", %{"kind" => "sign_in", "name" => "acme-login"})

      assert %{"ok" => true} = json_response(conn, 200)
      assert :error = Clinch.resolve({:sign_in, "acme-login"})
    end

    test "reports a miss rather than succeeding silently", %{conn: conn} do
      conn = delete(conn, ~p"/api/clinch", %{"kind" => "sign_in", "name" => "never-stored"})
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "the surface itself" do
    test "there is no GET — nothing returns a value over HTTP", %{conn: conn} do
      conn = conn |> auth(ApiToken.value()) |> get("/api/clinch")

      assert conn.status == 404,
             "a GET on /api/clinch resolved — the read path must not exist"
    end
  end
end
