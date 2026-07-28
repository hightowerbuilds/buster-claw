defmodule BusterClaw.Commands.JournalTest do
  # async: false — points the global :workspace_root at a tmp journal dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Commands

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmd_journal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "journal commands are in the catalog at the expected tiers" do
    assert Commands.command_tier("journal_append") == :restricted
    assert Commands.command_type("journal_append") == :mutate
    refute Commands.command_gated?("journal_append")

    assert Commands.command_tier("journal_read") == :safe
    assert Commands.command_type("journal_read") == :read
  end

  test "journal_append writes an agent entry into today's notes" do
    assert {:ok, day} = Commands.journal_append(%{"text" => "Cleared the queue."})

    assert day.body =~ "Cleared the queue."
    refute day.body =~ "OPERATOR"
    assert {:error, :blank} = Commands.journal_append(%{"text" => "  "})
    assert {:error, :missing_text} = Commands.journal_append(%{})
  end

  test "journal_read defaults to today and reads empty on a fresh day" do
    assert {:ok, %{body: ""}} = Commands.journal_read(%{})

    {:ok, _} = Commands.journal_append(%{"text" => "First item."})
    assert {:ok, %{body: body}} = Commands.journal_read(%{})
    assert body =~ "First item."

    assert {:ok, %{name: "2001-01-01", body: ""}} =
             Commands.journal_read(%{"date" => "2001-01-01"})

    assert {:error, :invalid_date} = Commands.journal_read(%{"date" => "../etc/passwd"})
  end
end
