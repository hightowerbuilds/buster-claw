defmodule BusterClaw.JournalTest do
  # async: false — points the global :workspace_root at a tmp journal dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Journal

  @noon ~N[2026-07-24 12:05:00]

  setup do
    root = Path.join(System.tmp_dir!(), "bc_journal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "first append creates the day's document with a title line", %{root: root} do
    assert {:ok, day} = Journal.append("Booted the shift; queue empty.", :agent, now: @noon)

    assert day.name == "2026-07-24"
    assert day.body =~ "# Minutes — 2026-07-24"
    assert day.body =~ "###### 12:05\n"
    assert day.body =~ "Booted the shift; queue empty."
    assert File.exists?(Path.join([root, "journal", "2026-07-24.md"]))
  end

  test "appends land chronologically in the same document; operator entries are marked" do
    {:ok, _} = Journal.append("Handled dispatch #12.", :agent, now: @noon)

    {:ok, day} =
      Journal.append("Remember to renew the domain.", :operator, now: ~N[2026-07-24 14:30:00])

    assert [%{name: "2026-07-24"}] = Journal.list()
    assert day.body =~ "###### 12:05\n\nHandled dispatch #12."
    assert day.body =~ "###### 14:30 — OPERATOR\n\nRemember to renew the domain."

    # Chronological: the later entry is after the earlier one, title only once.
    {first, second} = {index_of(day.body, "12:05"), index_of(day.body, "14:30")}
    assert first < second
    assert day.body |> String.split("# Minutes") |> length() == 2
  end

  test "a new day gets its own document" do
    {:ok, _} = Journal.append("Yesterday's wrap.", :agent, now: ~N[2026-07-23 23:50:00])
    {:ok, _} = Journal.append("Fresh morning.", :agent, now: @noon)

    assert [%{name: "2026-07-24"}, %{name: "2026-07-23"}] = Journal.list()
    assert Journal.get("2026-07-23").body =~ "Yesterday's wrap."
    refute Journal.get("2026-07-24").body =~ "Yesterday's wrap."
  end

  test "blank entries are rejected and mint no file" do
    assert {:error, :blank} = Journal.append("   \n", :agent, now: @noon)
    assert Journal.list() == []
  end

  test "append broadcasts the day over PubSub" do
    :ok = Journal.subscribe()
    {:ok, _} = Journal.append("ping", :agent, now: @noon)
    assert_receive {:journal_appended, "2026-07-24"}
  end

  test "get rejects non-date names outright", %{root: root} do
    File.write!(Path.join(root, "secret.md"), "outside")

    assert Journal.get("../secret") == nil
    assert Journal.get("not-a-date") == nil
    assert Journal.get("2026-07-24") == nil
  end

  test "list ignores non-date and non-md files", %{root: root} do
    {:ok, _} = Journal.append("real", :agent, now: @noon)
    File.write!(Path.join([root, "journal", "scratch.md"]), "x")
    File.write!(Path.join([root, "journal", "2026-07-23.txt"]), "x")

    assert [%{name: "2026-07-24"}] = Journal.list()
  end

  defp index_of(string, substring) do
    {index, _len} = :binary.match(string, substring)
    index
  end
end
