defmodule BusterClaw.TerminalPaintTest do
  @moduledoc """
  Phase 0's proof: a broadcast made by something with no socket reaches a mounted
  LiveView as a client event.

  This is the whole feature's foundation. Without it a command cannot change what
  a terminal looks like at all, because the selected theme lives in the browser's
  `localStorage` and nothing on the server knows it.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.{TerminalPaint, TerminalTheme}

  @palette %{
    "background" => "#101010",
    "foreground" => "#eeeeee",
    "cursor" => "#ff4d1c",
    "cursorAccent" => "#101010",
    "selectionBackground" => "#333333",
    "black" => "#101010",
    "red" => "#ff5555",
    "green" => "#50fa7b",
    "yellow" => "#f1fa8c",
    "blue" => "#8be9fd",
    "magenta" => "#ff79c6",
    "cyan" => "#8be9fd",
    "white" => "#eeeeee",
    "brightBlack" => "#555555",
    "brightRed" => "#ff6e6e",
    "brightGreen" => "#69ff94",
    "brightYellow" => "#ffffa5",
    "brightBlue" => "#d6acff",
    "brightMagenta" => "#ff92df",
    "brightCyan" => "#a4ffff",
    "brightWhite" => "#ffffff"
  }

  test "a bare selection reaches an open surface", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/terminal")

    :ok = TerminalPaint.announce("nord")

    assert_push_event(view, "bc-term-apply", %{key: "nord", palette: nil})
  end

  test "a paint carries the palette to install before selecting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/terminal")

    :ok = TerminalPaint.announce("agent", @palette)

    assert_push_event(view, "bc-term-apply", %{key: "agent", palette: palette})
    assert palette["foreground"] == "#eeeeee"
  end

  test "it reaches a surface that is not the terminal, because the dock is everywhere",
       %{conn: conn} do
    {:ok, home, _html} = live(conn, ~p"/")

    :ok = TerminalPaint.announce("monokai")

    assert_push_event(home, "bc-term-apply", %{key: "monokai"})
  end

  test "every open surface hears it, not just the one that asked", %{conn: conn} do
    {:ok, one, _html} = live(conn, ~p"/terminal")
    {:ok, two, _html} = live(conn, ~p"/")

    :ok = TerminalPaint.announce("nord")

    assert_push_event(one, "bc-term-apply", %{key: "nord"})
    assert_push_event(two, "bc-term-apply", %{key: "nord"})
  end

  test "the existing custom-theme broadcast is left alone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/terminal")

    # `{:terminal_theme, custom}` announces that the operator EDITED their saved
    # palette. It must not be reinterpreted as "wear this now" — the editor does
    # not re-select on save — and it must not reach a LiveView with no clause for
    # it, which is exactly what happened when these shared a topic.
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      TerminalTheme.topic(),
      {:terminal_theme, nil}
    )

    refute_push_event(view, "bc-term-apply", %{}, 100)
  end
end
