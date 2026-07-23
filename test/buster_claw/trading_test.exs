defmodule BusterClaw.TradingTest do
  # async: false — points the global :workspace_root at a tmp dir. DataCase for
  # the Settings-backed snapshot cache.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Trading

  setup do
    root = Path.join(System.tmp_dir!(), "bc_trading_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "seeds the Robinhood MCP config once and never overwrites operator edits", %{root: root} do
    path = Trading.ensure_mcp_config()
    assert path == Path.join([root, "mcp", "robinhood.json"])

    config = path |> File.read!() |> Jason.decode!()
    server = config["mcpServers"]["robinhood"]
    assert server["type"] == "http"
    assert server["url"] == "https://agent.robinhood.com/mcp/trading"

    # Operator edits win: a second call must not clobber the file.
    File.write!(path, ~s({"mcpServers": {"robinhood": {"custom": true}}}\n))
    assert Trading.ensure_mcp_config() == path
    assert File.read!(path) =~ "custom"
  end

  test "chat_opts scope the conversation to exactly the seeded server" do
    opts = Trading.chat_opts()
    extra = Keyword.fetch!(opts, :extra_cli_args)

    assert "--strict-mcp-config" in extra
    assert "--mcp-config" in extra
    assert Enum.any?(extra, &String.ends_with?(&1, "mcp/robinhood.json"))
  end

  test "the system prompt carries the money-truthfulness rules" do
    prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

    assert prompt =~ "real money"
    assert prompt =~ "list_positions"
    assert prompt =~ "never invent prices"
    assert prompt =~ "never simulate"
  end

  describe "parse_snapshot/1" do
    test "accepts clean JSON and stamps fetched_at app-side" do
      out =
        ~s({"account": "••••6587", "value": 2.38, "cash": 2.38, "buying_power": 2.38, "positions": []})

      assert {:ok, snap} = Trading.parse_snapshot(out)
      assert snap["value"] == 2.38
      assert snap["positions"] == []
      assert {:ok, _at, _} = DateTime.from_iso8601(snap["fetched_at"])
    end

    test "tolerates prose/stderr noise around the JSON" do
      out = """
      some warning on stderr
      {"account": "••••6587", "value": 100.5, "cash": 50.0, "buying_power": 50.0,
       "positions": [{"symbol": "VOO", "quantity": 0.1, "value": 50.5}]}
      trailing chatter
      """

      assert {:ok, snap} = Trading.parse_snapshot(out)
      assert [%{"symbol" => "VOO"}] = snap["positions"]
    end

    test "a reported tool failure surfaces as a robinhood error" do
      assert {:error, {:robinhood, msg}} =
               Trading.parse_snapshot(~s({"error": "not authenticated"}))

      assert msg =~ "authenticated"
    end

    test "garbage and non-numeric payloads are rejected" do
      assert {:error, :bad_snapshot} = Trading.parse_snapshot("no json here at all")

      assert {:error, :bad_snapshot} =
               Trading.parse_snapshot(~s({"value": "lots", "cash": 1, "buying_power": 1}))
    end
  end

  test "snapshot cache round-trips through Settings and knows staleness" do
    assert Trading.cached_snapshot() == :none

    {:ok, snap} =
      Trading.parse_snapshot(
        ~s({"account": "••••6587", "value": 2.38, "cash": 2.38, "buying_power": 2.38, "positions": []})
      )

    Trading.store_snapshot(snap)
    assert {:ok, cached} = Trading.cached_snapshot()
    assert cached["value"] == 2.38
    refute Trading.snapshot_stale?(cached)

    old = Map.put(cached, "fetched_at", "2020-01-01T00:00:00Z")
    assert Trading.snapshot_stale?(old)
    assert Trading.snapshot_stale?(%{})
  end
end
