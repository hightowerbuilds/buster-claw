defmodule BusterClawWeb.MemoryLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Memory

  test "creates, edits, and deletes a memory from the UI", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, BusterClawWeb.MemoryLive)
    assert html =~ "No memories recorded yet"

    html =
      view
      |> form("#memory-form", %{
        memory: %{
          created_at: "2026-05-07T15:00:00Z",
          text: "Remember the rewrite migration."
        }
      })
      |> render_submit()

    assert html =~ "Memory saved."
    assert html =~ "Remember the rewrite migration."
    assert [memory] = Memory.list_memories()

    html =
      view
      |> element("button[phx-click='edit'][phx-value-id='#{memory.id}']")
      |> render_click()

    assert html =~ "Edit Memory"

    html =
      view
      |> form("#memory-form", %{
        memory: %{
          created_at: "2026-05-07T15:00:00Z",
          text: "Remember idempotent imports."
        }
      })
      |> render_submit()

    assert html =~ "Remember idempotent imports."
    assert [%{text: "Remember idempotent imports."} = memory] = Memory.list_memories()

    html =
      view
      |> element("button[phx-click='delete'][phx-value-id='#{memory.id}']")
      |> render_click()

    assert html =~ "No memories recorded yet"
    assert [] = Memory.list_memories()
  end
end
