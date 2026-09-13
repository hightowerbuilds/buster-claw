defmodule BusterClawWeb.DutyDockLiveTest do
  # async: false — global app env (workspace root, :agent_cli) and the STOP file.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.{Dispatch, Google, Orchestration, TrustedSenders}

  setup do
    tmp = Path.join(System.tmp_dir!(), "bc_dock_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "memory"))
    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :workspace_root, tmp)
    Application.delete_env(:buster_claw, :agent_cli)

    on_exit(fn ->
      if prev_ws,
        do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
        else: Application.delete_env(:buster_claw, :workspace_root)

      if prev_cli,
        do: Application.put_env(:buster_claw, :agent_cli, prev_cli),
        else: Application.delete_env(:buster_claw, :agent_cli)

      Orchestration.clear_kill_switch()
    end)

    :ok
  end

  defp ready! do
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    {:ok, _} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "id",
        "client_secret" => "s",
        "refresh_token" => "r"
      })

    {:ok, _} = TrustedSenders.add_entry("boss@example.com")
  end

  defp dock(view), do: find_live_child(view, "bc-duty-dock-live")

  test "mounts on every page as a sticky child", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/calendar")
    assert dock(view), "expected the sticky duty control on /calendar"
    assert has_element?(dock(view), "#bc-duty-dock")
  end

  test "blocked: names the first missing thing and links to it, offers no button", %{conn: conn} do
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})
    {:ok, view, _} = live(conn, ~p"/")
    d = dock(view)

    assert has_element?(d, ~s(#bc-duty-dock[data-state="blocked"]))
    assert has_element?(d, "#bc-dock-on-duty-blocked", "Connect Google first")
    refute has_element?(d, "#bc-dock-on-duty")
    refute has_element?(d, "#bc-dock-stand-down")
  end

  test "ready: one click goes on duty; the control flips and counts the queue", %{conn: conn} do
    ready!()
    {:ok, view, _} = live(conn, ~p"/")
    d = dock(view)

    assert has_element?(d, ~s(#bc-duty-dock[data-state="off"]))
    d |> element("#bc-dock-on-duty") |> render_click()

    assert Orchestration.shift_active?()
    assert Orchestration.active_shift().unattended
    assert has_element?(d, ~s(#bc-duty-dock[data-state="on"]))
    assert has_element?(d, "#bc-dock-duty-link", "On duty")
    refute render(d) =~ "queued"

    {:ok, _} = Dispatch.enqueue(%{source: "gmail", subject: "Hi", dedupe_key: "dock-1"})
    assert has_element?(d, "#bc-dock-duty-link", "1 queued")
  end

  test "stand down is one click, latches STOP, and the control returns to off", %{conn: conn} do
    ready!()
    {:ok, _} = Orchestration.start_shift(unattended: true)
    {:ok, view, _} = live(conn, ~p"/terminal")
    d = dock(view)

    assert has_element?(d, "#bc-dock-stand-down")
    refute has_element?(d, "#bc-dock-stand-down[data-claw-confirm]")
    d |> element("#bc-dock-stand-down") |> render_click()

    refute Orchestration.shift_active?()
    assert Orchestration.kill_switch_engaged?()
    assert has_element?(d, ~s(#bc-duty-dock[data-state="off"]))
  end

  test "follows a shift started elsewhere without a reload", %{conn: conn} do
    ready!()
    {:ok, view, _} = live(conn, ~p"/")
    d = dock(view)
    assert has_element?(d, "#bc-dock-on-duty")

    {:ok, _} = Orchestration.start_shift(unattended: true)
    assert has_element?(d, "#bc-dock-stand-down")

    {:ok, _} = Orchestration.stop_shift()
    assert has_element?(d, "#bc-dock-on-duty")
  end
end
