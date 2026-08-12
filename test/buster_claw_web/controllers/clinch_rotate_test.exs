defmodule BusterClawWeb.ClinchRotateTest do
  @moduledoc """
  `POST /api/clinch/rotate` — the thing that makes Phase 4's acceptance operable
  rather than merely implemented.

  Rotation is credential **management**, so it sits behind the same trusted-token
  floor as storing one and is deliberately absent from the command catalog: an
  agent cannot reach it because there is nothing to reach, not because a tier
  said no.
  """
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Clinch

  @old "rotate-old-key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @new "rotate-new-key-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    prev = Application.get_env(:buster_claw, :secret_key_base)
    prev_env = System.get_env("SECRET_KEY_BASE")
    System.delete_env("SECRET_KEY_BASE")
    Application.put_env(:buster_claw, :secret_key_base, @old)

    on_exit(fn ->
      System.delete_env("SECRET_KEY_BASE")
      Application.put_env(:buster_claw, :secret_key_base, prev)
      if prev_env, do: System.put_env("SECRET_KEY_BASE", prev_env)
    end)

    :ok
  end

  # `value/0` is the full token — the one the shell holds. `mcp_value/0` and
  # `agent_value/0` are valid tokens that must NOT get through here.
  defp trusted(conn) do
    put_req_header(conn, "authorization", "Bearer #{BusterClaw.ApiToken.value()}")
  end

  describe "the gate" do
    test "an unauthenticated caller cannot rotate", %{conn: conn} do
      conn = post(conn, ~p"/api/clinch/rotate", %{"new_key" => @new})

      assert conn.status in [401, 403],
             "rotation must sit behind the trusted-token floor — it is credential " <>
               "management, and management is the half remote callers never get"
    end

    test "a valid but lesser token cannot rotate", %{conn: _conn} do
      for token <- [BusterClaw.ApiToken.mcp_value(), BusterClaw.ApiToken.agent_value()] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{token}")
          |> post(~p"/api/clinch/rotate", %{"new_key" => @new})

        assert conn.status in [401, 403],
               "a valid token is not a trusted one — the MCP token goes to external " <>
                 "agents and the agent token to runs that touched untrusted content"
      end
    end

    test "rotation is not on the command catalog at all" do
      names = Enum.map(BusterClaw.Commands.Catalog.entries(), & &1.name)

      refute Enum.any?(names, &(&1 =~ "rotate")),
             "a master-key rotation reachable from the catalog is reachable by an " <>
               "agent. The Clinch's split is structural: use, never manage."
    end
  end

  describe "rotating" do
    test "re-encrypts and switches the running app to the new key", %{conn: conn} do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "value")

      conn = conn |> trusted() |> post(~p"/api/clinch/rotate", %{"new_key" => @new})

      assert %{"ok" => true, "rekeyed" => rekeyed, "unreadable" => 0} = json_response(conn, 200)
      assert rekeyed >= 1

      # No restart: the endpoint puts the new key in the environment the vault
      # reads, so the very next resolve works.
      assert System.get_env("SECRET_KEY_BASE") == @new
      assert {:ok, "value"} = Clinch.resolve({:sign_in, "acme"})
    end

    test "never returns a credential value", %{conn: conn} do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "super-secret")

      conn = conn |> trusted() |> post(~p"/api/clinch/rotate", %{"new_key" => @new})
      body = json_response(conn, 200)

      refute inspect(body) =~ "super-secret"
    end

    test "refuses a rotation to the same key", %{conn: conn} do
      conn = conn |> trusted() |> post(~p"/api/clinch/rotate", %{"new_key" => @old})

      assert %{"ok" => false, "error" => "same_key"} = json_response(conn, 422)
    end

    test "refuses a missing key", %{conn: conn} do
      conn = conn |> trusted() |> post(~p"/api/clinch/rotate", %{})

      assert %{"ok" => false, "error" => "missing_new_key"} = json_response(conn, 422)
    end

    test "a refused rotation changes nothing", %{conn: conn} do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "value")

      conn |> trusted() |> post(~p"/api/clinch/rotate", %{"new_key" => @old})

      # Still the old key, still readable — a refusal must not half-apply.
      refute System.get_env("SECRET_KEY_BASE") == @old
      assert {:ok, "value"} = Clinch.resolve({:sign_in, "acme"})
    end
  end
end
