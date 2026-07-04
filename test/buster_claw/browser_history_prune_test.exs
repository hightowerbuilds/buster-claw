defmodule BusterClaw.BrowserHistoryPruneTest do
  # async: false — flips the global retention cap for the duration of the test.
  # The prune keeps the newest N ids *exactly* (gap-immune), so any concurrent
  # test holding <= N rows in its own sandboxed transaction is never touched.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserHistory

  setup do
    prev = Application.get_env(:buster_claw, :browser_history_max_entries)
    Application.put_env(:buster_claw, :browser_history_max_entries, 3)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:buster_claw, :browser_history_max_entries, prev),
        else: Application.delete_env(:buster_claw, :browser_history_max_entries)
    end)

    :ok
  end

  test "record prunes to the newest max_entries rows" do
    for i <- 1..6, do: {:ok, _} = BrowserHistory.record("https://s#{i}.com", "S#{i}")

    urls = BrowserHistory.list(:infinity) |> Enum.map(& &1.url)
    assert length(urls) == 3
    assert urls == ["https://s6.com", "https://s5.com", "https://s4.com"]
    # FTS is kept in sync by the delete trigger — a pruned row is unsearchable.
    assert {:ok, []} = BrowserHistory.search("s1")
  end
end
