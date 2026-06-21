defmodule BusterClaw.WalletPollerTest do
  # async: false — the poller runs in its own process against the shared sandbox.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.WalletPoller
  alias BusterClaw.Wallets

  defp wallet!(attrs \\ %{}) do
    {:ok, wallet} = Wallets.create_wallet(Map.merge(%{name: "Acme", type: "business"}, attrs))
    wallet
  end

  defp start_poller(opts) do
    opts = Keyword.merge([autostart: false, subscribe: false], opts)
    pid = start_supervised!({WalletPoller, opts})
    pid
  end

  test "tick polls a due market feed using the injected finance fn" do
    wallet = wallet!()
    {:ok, feed} = Wallets.create_feed(wallet, %{kind: "market", config: %{"symbol" => "AAPL"}})

    finance = fn "AAPL" ->
      {:ok,
       %{symbol: "AAPL", price: 199.5, source: "Stub", as_of: "2026-06-20", percent_change: 1.2}}
    end

    pid = start_poller(finance: finance)
    WalletPoller.tick_now(pid)
    # tick runs synchronously inside the GenServer; a sync call flushes the mailbox
    _ = :sys.get_state(pid)

    polled = Wallets.get_feed!(feed.id)
    assert polled.last_status == "ok"
    assert polled.last_value =~ "AAPL"
  end

  test "url feed detects content change across two polls" do
    wallet = wallet!()

    {:ok, feed} =
      Wallets.create_feed(wallet, %{kind: "url", config: %{"url" => "https://example.com"}})

    # first poll establishes a baseline hash
    [{:ok, after_first}] =
      Wallets.poll_due_feeds(
        fetch: fn _url -> {:ok, %{title: "Home", markdown: "v1", html: "<p>v1</p>"}} end
      )

    assert after_first.id == feed.id
    assert after_first.last_value =~ "unchanged"
    refute is_nil(after_first.last_content_hash)

    # second poll with different content → changed (poll the feed directly; the
    # due-interval check would otherwise skip it right after the first run)
    {:ok, after_second} =
      Wallets.poll_feed(Wallets.get_feed!(feed.id),
        fetch: fn _url -> {:ok, %{title: "Home", markdown: "v2", html: "<p>v2</p>"}} end
      )

    assert after_second.last_value =~ "changed"
  end

  test "feed records an error and keeps polling when the source fails" do
    wallet = wallet!()
    {:ok, feed} = Wallets.create_feed(wallet, %{kind: "market", config: %{"symbol" => "ZZZ"}})

    [{:ok, polled}] = Wallets.poll_due_feeds(finance: fn _ -> {:error, :not_configured} end)
    assert polled.id == feed.id
    assert polled.last_status == "error"
    assert polled.last_error =~ "not_configured"
  end

  test "Gmail dispatch events are recorded against gmail feeds" do
    wallet = wallet!()
    {:ok, feed} = Wallets.create_feed(wallet, %{kind: "gmail", config: %{}})

    pid = start_poller(subscribe: true)

    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      "dispatch",
      {:dispatch, :dispatch_item_queued,
       %{source: "gmail", sender: "store@shop.com", subject: "Receipt #42"}}
    )

    _ = :sys.get_state(pid)
    polled = Wallets.get_feed!(feed.id)
    assert polled.last_status == "ok"
    assert polled.last_value =~ "Receipt #42"
  end

  test "gmail feeds are not touched by the timer poll (event-driven only)" do
    wallet = wallet!()
    {:ok, feed} = Wallets.create_feed(wallet, %{kind: "gmail", config: %{}})

    assert [] == Wallets.poll_due_feeds()
    assert Wallets.get_feed!(feed.id).last_status == "never_run"
  end
end
