defmodule BusterClaw.Commands.WebHistoryTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.{BrowserHistory, Commands}

  test "history_recent returns the newest visit per url" do
    BrowserHistory.record("https://hex.pm", "Hex packages")
    BrowserHistory.record("https://hex.pm", "Hex — home")

    assert {:ok, %{entries: [%{url: "https://hex.pm", title: "Hex — home"}]}} =
             Commands.call("history_recent", %{"limit" => 5})
  end

  test "history_search is FTS-backed and requires a query" do
    BrowserHistory.record("https://hexdocs.pm/phoenix", "Phoenix docs")
    BrowserHistory.record("https://rust-lang.org", "Rust")

    assert {:ok, %{entries: [%{url: "https://hexdocs.pm/phoenix"}]}} =
             Commands.call("history_search", %{"query" => "phoenix"})

    assert {:error, :missing_query} = Commands.call("history_search", %{})
  end
end
