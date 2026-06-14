defmodule BusterClaw.BrowserHistoryTest do
  use ExUnit.Case, async: false

  alias BusterClaw.BrowserHistory

  setup do
    root = Path.join(System.tmp_dir!(), "bc-bh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "records newest-first and dedupes by url (moving repeats to the top)" do
    assert BrowserHistory.list() == []

    BrowserHistory.record("https://a.com", "A")
    BrowserHistory.record("https://b.com", "B")
    BrowserHistory.record("https://a.com", "A again")

    urls = BrowserHistory.list() |> Enum.map(& &1["url"])
    assert urls == ["https://a.com", "https://b.com"]
    assert [%{"label" => "A again"} | _] = BrowserHistory.list()
  end

  test "defaults the label to the url and records workspace-file paths" do
    BrowserHistory.record(
      "http://127.0.0.1:4000/ws/file?path=/library/notes.md",
      "/library/notes.md"
    )

    BrowserHistory.record("https://c.com")

    assert [%{"url" => "https://c.com", "label" => "https://c.com"}, ws] = BrowserHistory.list()
    assert ws["label"] == "/library/notes.md"
  end

  test "ignores blank urls" do
    assert BrowserHistory.record("", "x") == :ok
    assert BrowserHistory.list() == []
  end
end
