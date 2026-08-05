defmodule BusterClawWeb.LookupKeyboardTest do
  @moduledoc """
  Arrowing through the ticker lookup. Pure LiveView — `phx-keydown` and an index
  in the assigns, no JS hook — so the whole interaction is assertable here.
  """
  use BusterClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    # `Edgar.search/2` reads its ticker map from `:persistent_term` and only
    # fetches when that is missing or stale. Seeding it makes the search local
    # and deterministic — no network, no production seam invented for a test.
    map = %{
      "AAPL" => %{cik: "0000320193", title: "Apple Inc."},
      "AMD" => %{cik: "0000002488", title: "Advanced Micro Devices"},
      "AMZN" => %{cik: "0001018724", title: "Amazon.com Inc."}
    }

    expires_at = System.monotonic_time(:millisecond) + 60_000
    :persistent_term.put({BusterClaw.Finance.Edgar, :ticker_map}, {map, expires_at})
    on_exit(fn -> :persistent_term.erase({BusterClaw.Finance.Edgar, :ticker_map}) end)
    :ok
  end

  defp cursor(view), do: :sys.get_state(view.pid).socket.assigns.lookup_cursor

  defp with_matches(conn) do
    {:ok, view, _html} = live(conn, ~p"/trading")
    render_change(view, "lookup_search", %{"query" => "am"})

    assert :sys.get_state(view.pid).socket.assigns.lookup_matches != [],
           "the seeded ticker map should have produced matches"

    view
  end

  test "arrow down highlights the first match, then the next", %{conn: conn} do
    view = with_matches(conn)

    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    assert cursor(view) == 0

    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    assert cursor(view) == 1
  end

  test "arrow up from nothing selects the last, and clamps at the top", %{conn: conn} do
    view = with_matches(conn)
    last = length(:sys.get_state(view.pid).socket.assigns.lookup_matches) - 1

    render_keydown(view, "lookup_key", %{"key" => "ArrowUp"})
    assert cursor(view) == last

    for _ <- 0..(last + 3), do: render_keydown(view, "lookup_key", %{"key" => "ArrowUp"})

    # Clamped, not wrapped: jumping from the top back to the bottom reads as a
    # glitch in a box this small.
    assert cursor(view) == 0
  end

  test "arrow down clamps at the bottom", %{conn: conn} do
    view = with_matches(conn)
    last = length(:sys.get_state(view.pid).socket.assigns.lookup_matches) - 1

    for _ <- 0..(last + 3), do: render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    assert cursor(view) == last
  end

  test "enter opens the highlighted match", %{conn: conn} do
    view = with_matches(conn)
    [first | _] = :sys.get_state(view.pid).socket.assigns.lookup_matches

    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    render_keydown(view, "lookup_key", %{"key" => "Enter"})

    assigns = :sys.get_state(view.pid).socket.assigns
    panel = Map.get(assigns.lookup, assigns.active_tab)

    assert panel.symbol == first.symbol
    # Opening consumes the search: no stale list, no stale index.
    assert assigns.lookup_matches == []
    assert assigns.lookup_cursor == nil
  end

  test "enter with no highlight opens nothing", %{conn: conn} do
    view = with_matches(conn)
    render_keydown(view, "lookup_key", %{"key" => "Enter"})

    assigns = :sys.get_state(view.pid).socket.assigns
    assert Map.get(assigns.lookup, assigns.active_tab) == nil
    assert assigns.lookup_matches != []
  end

  test "escape drops the highlight without clearing the search", %{conn: conn} do
    view = with_matches(conn)
    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    render_keydown(view, "lookup_key", %{"key" => "Escape"})

    assert cursor(view) == nil
    assert :sys.get_state(view.pid).socket.assigns.lookup_query == "am"
  end

  test "an ordinary keystroke does not move the highlight", %{conn: conn} do
    view = with_matches(conn)
    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    render_keydown(view, "lookup_key", %{"key" => "x"})

    assert cursor(view) == 0
  end

  # A stale index pointing at a row that no longer exists is the bug this
  # prevents: searching again must reset it.
  test "a new search resets the highlight", %{conn: conn} do
    view = with_matches(conn)
    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})

    render_change(view, "lookup_search", %{"query" => "aa"})
    assert cursor(view) == nil
  end

  test "arrowing with no matches at all is a no-op, not a crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/trading")

    render_keydown(view, "lookup_key", %{"key" => "ArrowDown"})
    render_keydown(view, "lookup_key", %{"key" => "Enter"})

    assert cursor(view) == nil
  end
end
