defmodule BusterClaw.TradingBrokerTest do
  use BusterClaw.DataCase, async: false

  import ExUnit.CaptureLog

  alias BusterClaw.Repo
  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingBroker.MCPClient
  alias BusterClaw.TradingBroker.OAuth
  alias BusterClaw.Vault
  alias BusterClawWeb.TradingBrokerOAuth

  @stub BusterClaw.TradingBrokerHTTP
  @resource "https://agent.robinhood.com/mcp/trading"
  @redirect "http://127.0.0.1:4000/trading/broker/oauth/callback"

  setup do
    Req.Test.verify_on_exit!()

    previous_redirect =
      Application.get_env(:buster_claw, :trading_broker_redirect_base_url)

    Application.put_env(
      :buster_claw,
      :trading_broker_redirect_base_url,
      "http://127.0.0.1:4000"
    )

    on_exit(fn ->
      if previous_redirect do
        Application.put_env(
          :buster_claw,
          :trading_broker_redirect_base_url,
          previous_redirect
        )
      else
        Application.delete_env(:buster_claw, :trading_broker_redirect_base_url)
      end
    end)

    :ok
  end

  test "discovers only Robinhood's pinned OAuth endpoints and registers a public PKCE client" do
    stub_oauth()

    assert {:ok, connection} = OAuth.register_client(@redirect)
    assert connection.client_id == "buster-client-id"
    assert connection.status == "authorizing"

    verifier = OAuth.generate_code_verifier()

    assert {:ok, url} =
             OAuth.authorization_url(connection, @redirect, "signed-state", verifier)

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert {uri.scheme, uri.host, uri.path} == {"https", "robinhood.com", "/oauth"}
    assert params["client_id"] == "buster-client-id"
    assert params["redirect_uri"] == @redirect
    assert params["resource"] == @resource
    assert params["scope"] == "internal"
    assert params["state"] == "signed-state"
    assert params["code_challenge_method"] == "S256"
    assert params["code_challenge"] == OAuth.code_challenge(verifier)
    refute url =~ verifier
  end

  test "rejects poisoned discovery endpoints before sending credentials" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/.well-known/oauth-protected-resource/mcp/trading" ->
          Req.Test.json(conn, resource_metadata())

        "/.well-known/oauth-authorization-server/mcp/trading" ->
          Req.Test.json(
            conn,
            authorization_metadata(%{
              "token_endpoint" => "https://attacker.example/token"
            })
          )
      end
    end)

    assert {:error, :invalid_broker_authorization_metadata} = OAuth.discover()
    assert TradingBroker.connection() == nil
  end

  test "exchanges PKCE code, encrypts tokens at rest, and rotates refresh tokens" do
    stub_oauth()
    assert {:ok, connection} = OAuth.register_client(@redirect)

    assert {:ok, connected} =
             OAuth.exchange_code(connection, "callback-code", @redirect, "pkce-verifier")

    assert connected.status == "authorizing"
    assert connected.access_token == "access-token"
    assert connected.refresh_token == "refresh-token"
    refute inspect(connected) =~ "access-token"
    refute inspect(connected) =~ "refresh-token"

    %{rows: [[access_ciphertext, refresh_ciphertext]]} =
      Repo.query!(
        "SELECT access_token, refresh_token FROM trading_broker_connections WHERE id = ?",
        [connected.id]
      )

    refute access_ciphertext == "access-token"
    refute refresh_ciphertext == "refresh-token"
    assert Vault.ciphertext?(access_ciphertext)
    assert Vault.ciphertext?(refresh_ciphertext)

    expired = %{
      connected
      | access_token_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
    }

    {:ok, _expired} =
      TradingBroker.update_connection(connected, %{
        access_token_expires_at: expired.access_token_expires_at
      })

    assert {:ok, "rotated-access-token"} = OAuth.access_token()
    refreshed = TradingBroker.connection()
    assert refreshed.refresh_token == "rotated-refresh-token"
    assert refreshed.status == "authorizing"
  end

  test "direct MCP health discovers schemas and stores HMAC account identities" do
    stub_oauth()
    stub_mcp()
    seed_tokens()

    health =
      capture_log(fn ->
        assert {:ok, health} = MCPClient.health()
        send(self(), {:health, health})
      end)

    refute health =~ "RH-12345678"
    assert_received {:health, health}
    assert health.status == :connected
    assert "get_accounts" in health.tools
    assert "review_equity_order" in health.tools

    assert [%{label: "Agentic Investing"} = account] = health.accounts
    assert account.agentic
    assert account.can_trade
    assert health.agentic_account.account_key == account.account_key
    refute account.account_key =~ "12345678"
    refute inspect(account) =~ "12345678"

    assert account.account_key ==
             Vault.fingerprint("robinhood-account", "RH-12345678")

    %{rows: [[broker_ciphertext]]} =
      Repo.query!(
        "SELECT broker_account_id FROM trading_broker_accounts WHERE id = ?",
        [account.id]
      )

    refute broker_ciphertext == "RH-12345678"
    assert Vault.ciphertext?(broker_ciphertext)
    assert TradingBroker.connection().status == "connected"
  end

  test "write tools are unreachable even when a caller supplies their name" do
    assert {:error, :broker_tool_not_allowed} =
             MCPClient.call_tool("place_equity_order", %{
               "symbol" => "AAPL",
               "side" => "buy",
               "quantity" => 1
             })

    assert TradingBroker.connection() == nil
  end

  test "web authorization state encrypts the PKCE verifier in a signed short-lived token" do
    stub_oauth()

    assert {:ok, url} = TradingBrokerOAuth.authorization_url()
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    assert {:ok, state_data} = TradingBrokerOAuth.verify_state(state)
    assert state_data.client_id == "buster-client-id"
    assert state_data.redirect_uri == TradingBrokerOAuth.callback_url()
    assert is_binary(state_data.code_verifier)
    refute url =~ state_data.code_verifier

    assert {:ok, signed_data} =
             Phoenix.Token.verify(
               BusterClawWeb.Endpoint,
               "trading-broker-oauth-state-v1",
               state,
               max_age: 600
             )

    refute Map.has_key?(signed_data, :code_verifier)
    refute signed_data.encrypted_verifier =~ state_data.code_verifier
  end

  defp seed_tokens do
    assert {:ok, connection} = TradingBroker.put_client_id("buster-client-id")

    assert {:ok, _connection} =
             TradingBroker.put_tokens(%{
               "access_token" => "access-token",
               "refresh_token" => "refresh-token",
               "expires_in" => 3600,
               "scope" => "internal"
             })

    connection
  end

  defp stub_oauth do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/.well-known/oauth-protected-resource/mcp/trading"} ->
          Req.Test.json(conn, resource_metadata())

        {"GET", "/.well-known/oauth-authorization-server/mcp/trading"} ->
          Req.Test.json(conn, authorization_metadata())

        {"POST", "/oauth/trading/register"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          registration = Jason.decode!(body)

          assert registration["token_endpoint_auth_method"] == "none"
          assert registration["redirect_uris"] == [@redirect]
          assert registration["grant_types"] == ["authorization_code", "refresh_token"]

          Req.Test.json(conn, %{"client_id" => "buster-client-id"})

        {"POST", "/oauth2/token/"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)

          case params["grant_type"] do
            "authorization_code" ->
              assert params["code"] == "callback-code"
              assert params["code_verifier"] == "pkce-verifier"
              assert params["resource"] == @resource

              Req.Test.json(conn, %{
                "access_token" => "access-token",
                "refresh_token" => "refresh-token",
                "expires_in" => 3600,
                "scope" => "internal"
              })

            "refresh_token" ->
              assert params["refresh_token"] == "refresh-token"
              assert params["resource"] == @resource

              Req.Test.json(conn, %{
                "access_token" => "rotated-access-token",
                "refresh_token" => "rotated-refresh-token",
                "expires_in" => 3600,
                "scope" => "internal"
              })
          end
      end
    end)
  end

  defp stub_mcp do
    Req.Test.stub(@stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-token"]
      assert Plug.Conn.get_req_header(conn, "mcp-protocol-version") == ["2025-11-25"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Req.Test.json(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "robinhood", "version" => "1"}
            }
          })

        "notifications/initialized" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-123"]
          Plug.Conn.send_resp(conn, 202, "")

        "tools/list" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-123"]

          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "tools" => [
                %{"name" => "get_accounts", "inputSchema" => %{"type" => "object"}},
                %{"name" => "review_equity_order", "inputSchema" => %{"type" => "object"}},
                %{"name" => "place_equity_order", "inputSchema" => %{"type" => "object"}}
              ]
            }
          })

        "tools/call" ->
          assert request["params"]["name"] == "get_accounts"

          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "structuredContent" => %{
                "accounts" => [
                  %{
                    "account_number" => "RH-12345678",
                    "nickname" => "Agentic Investing",
                    "agentic_allowed" => true,
                    "brokerage_account_type" => "individual",
                    "type" => "margin",
                    "state" => "active",
                    "deactivated" => false,
                    "permanently_deactivated" => false
                  }
                ]
              }
            }
          })
      end
    end)
  end

  defp resource_metadata do
    %{
      "authorization_servers" => [@resource],
      "bearer_methods_supported" => ["header"],
      "resource" => @resource,
      "scopes_supported" => ["internal"]
    }
  end

  defp authorization_metadata(overrides \\ %{}) do
    Map.merge(
      %{
        "authorization_endpoint" => "https://robinhood.com/oauth",
        "code_challenge_methods_supported" => ["S256"],
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "issuer" => @resource,
        "registration_endpoint" => "https://agent.robinhood.com/oauth/trading/register",
        "response_types_supported" => ["code"],
        "scopes_supported" => ["internal"],
        "token_endpoint" => "https://api.robinhood.com/oauth2/token/",
        "token_endpoint_auth_methods_supported" => ["none"]
      },
      overrides
    )
  end
end
