defmodule BusterClawWeb.VoiceLiveEngineTest do
  @moduledoc """
  The engine panel, which reports on a binary that is not installed here and
  cannot be. Application env steers resolution, which is global, so this cannot
  be async and cannot live in `voice_live_test.exs` beside the async cases.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Voice.Engine

  setup do
    previous = Application.get_env(:buster_claw, :voxcpm_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :voxcpm_path, previous),
        else: Application.delete_env(:buster_claw, :voxcpm_path)

      Engine.refresh()
    end)

    :ok
  end

  test "with no engine, it says so and gives the line to fix it", %{conn: conn} do
    absent()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ "Not installed"
    assert html =~ "pip install voxcpm"
    # The honest framing: absence is the normal state, not a broken one.
    assert html =~ "your Mac&#39;s own voices" or html =~ "your Mac's own voices"
    # Nothing to run when there is nothing installed.
    refute html =~ "engine-verify"
  end

  test "an install that cannot be run gets a different sentence from a missing one", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "voxcpm_noexec_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o644)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ "cannot be run"
    refute html =~ "Not installed."
  end

  test "an installed engine reports its path and device, and offers to run it", %{conn: conn} do
    path = stub()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ path
    assert html =~ "engine-verify"
    # The install instructions are for people who need them.
    refute html =~ "pip install voxcpm"
  end

  test "Check again re-reads the disk, which is the whole point of it", %{conn: conn} do
    absent()
    {:ok, view, html} = live(conn, ~p"/voice")
    assert html =~ "Not installed"

    # Install it underneath, exactly as an operator would while the page is open.
    stub()

    html = view |> element("button[phx-click=engine-recheck]") |> render_click()

    assert html =~ "engine-verify"
    refute html =~ "Not installed"
  end

  test "Run it reports what the binary actually did", %{conn: conn} do
    stub(3)
    {:ok, view, _html} = live(conn, ~p"/voice")

    view |> element("button[phx-click=engine-verify]") |> render_click()

    # The task result arrives as a message; render/1 after it lands.
    assert eventually(fn -> render(view) =~ "exited 3" end),
           "expected the failing exit status to reach the page"
  end

  defp absent do
    Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
    Engine.refresh()
  end

  defp stub(exit_code \\ 0) do
    path = Path.join(System.tmp_dir!(), "voxcpm_stub_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nexit #{exit_code}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
    path
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
