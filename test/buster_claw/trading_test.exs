defmodule BusterClaw.TradingTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use ExUnit.Case, async: false

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
end
