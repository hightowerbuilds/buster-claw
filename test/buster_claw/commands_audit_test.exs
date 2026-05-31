defmodule BusterClaw.CommandsAuditTest do
  @moduledoc "Phase 1: Commands.call/3 feeds the Sentinel audit spine."
  use BusterClaw.DataCase, async: true

  alias BusterClaw.{Commands, Sentinel}

  test "a refused restricted MCP call records a critical security_block" do
    assert {:error, :requires_confirmation} =
             Commands.call("source_create", %{"url" => "https://x.test/f", "type" => "rss"},
               caller: :mcp
             )

    assert [%{category: "security_block", severity: "critical", caller: "mcp"} = event] =
             Sentinel.list_events(limit: 50)
             |> Enum.filter(&(&1.category == "security_block"))

    assert event.metadata["command"] == "source_create"
  end

  test "a consequential trusted call records a command_invoke" do
    assert {:ok, _} =
             Commands.call("source_create", %{"url" => "https://y.test/f", "type" => "rss"},
               caller: :trusted
             )

    assert Enum.any?(
             Sentinel.list_events(limit: 50),
             &(&1.category == "command_invoke" and &1.metadata["command"] == "source_create" and
                 &1.metadata["outcome"] == "ok")
           )
  end

  test "pure reads are not audited" do
    assert {:ok, _} = Commands.call("source_list", %{}, caller: :mcp)
    refute Enum.any?(Sentinel.list_events(limit: 50), &(&1.metadata["command"] == "source_list"))
  end
end
