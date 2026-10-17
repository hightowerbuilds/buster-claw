defmodule BusterClawWeb.NotifySettingsLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Sound

  setup do
    root = Path.join(System.tmp_dir!(), "bc_ntfset_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    File.write!(Path.join([root, "sounds", "bongos.wav"]), "x")
    File.write!(Path.join([root, "sounds", "wilhelm.wav"]), "x")

    {:ok, root: root}
  end

  test "renders the sound board in the Settings sub-tab system", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/notify-settings")

    assert html =~ ~s(id="settings-tabs")
    assert html =~ ~s(id="settings-tab-notify")
    assert html =~ "Sound board"
    # Both seeded sounds are the operator's own: chips below the board, and an
    # option in every route's menu. Routing rows are present.
    assert html =~ ~s(data-own-sound="bongos.wav")
    assert html =~ ~s(data-own-sound="wilhelm.wav")
    assert html =~ ~s(value="wilhelm.wav")
    assert html =~ "Email"
    assert html =~ ~s(phx-hook="SoundPreview")
  end

  # One screen (10-17): no library listing of the bundled chimes, and every
  # route row carries its own ▶ and Test.
  test "the bundled chimes are in the menus, not listed as a library", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/notify-settings")

    refute html =~ "Sounds on deck"
    refute html =~ ~s(data-own-sound="boot.wav")
    assert has_element?(view, "#assign-email option[value='boot.wav']")

    for key <- Sound.route_keys() do
      assert has_element?(view, "[data-route='#{key}'] select[name='sound']"),
             "#{key} has no menu"

      assert has_element?(view, "[data-route='#{key}'] button[phx-click='test']"),
             "#{key} has no Test"

      assert has_element?(view, "[data-route='#{key}'] button[data-preview-url]"),
             "#{key} has no ▶"
    end
  end

  test "assigning a sound to an event persists the routing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    view
    |> form("#assign-email", %{"sound" => "wilhelm.wav"})
    |> render_change()

    assert Sound.sound_map() == %{"email" => "wilhelm.wav"}
    assert has_element?(view, "[data-route='email'][data-plays='wilhelm.wav']")
    assert has_element?(view, "[data-route='email'] option[value='wilhelm.wav'][selected]")
  end

  test "an invalid assignment is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    render_change(view, "assign", %{"key" => "email", "sound" => "missing.wav"})

    assert Sound.sound_map() == %{}
    assert render(view) =~ "Couldn&#39;t save that routing."
  end

  test "Test fires a real notification carrying the row's kind and source", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    render_click(view, "test", %{"key" => "email"})

    assert [notification] = Notifications.upcoming()
    assert notification.kind == "reminder"
    assert notification.source == "email"
    assert notification.label == "Notify test — Email"
  end

  test "deleting a sound removes it and its routings", %{conn: conn, root: root} do
    assert Sound.assign("alarm", "bongos.wav") == :ok
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    render_click(view, "delete_sound", %{"name" => "bongos.wav"})

    refute File.exists?(Path.join([root, "sounds", "bongos.wav"]))
    assert Sound.sound_map() == %{}
    # The library row (and its preview link) is gone; the flash may still name it.
    refute render(view) =~ "/notify/sound/bongos.wav"
  end

  describe "the SoundBoard keys (Phase 2)" do
    test "every Part II routing key has a visible row", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/notify-settings")

      for label <- [
            "Agent attention",
            "Confirm",
            "Shift end",
            "Blocked",
            "Browser",
            "Order",
            "Security",
            "Chimes",
            "Boot"
          ] do
        assert html =~ label, "missing row/group #{label}"
      end
    end

    test "silent sticks, and the row says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notify-settings")

      html =
        view
        |> element(~s(#assign-email))
        |> render_change(%{"key" => "email", "sound" => "silent"})

      assert Sound.sound_map()["email"] == "silent"
      assert html =~ ~s(data-route="email" data-plays="silent")
      # No file to preview, so the ▶ is disabled rather than pointing at nothing.
      assert has_element?(view, "[data-route='email'] button[disabled]:not([data-preview-url])")
      # And the resolution honors it end-to-end, not just the display.
      assert Sound.for_notification(%{kind: "reminder", source: "email"}) == nil
    end

    test "a bundled default is routable without any workspace file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notify-settings")

      view
      |> element(~s(#assign-confirm))
      |> render_change(%{"key" => "confirm", "sound" => "boot.wav"})

      assert Sound.sound_map()["confirm"] == "boot.wav"
      assert Sound.resolved("confirm") == "boot.wav"
    end

    test "Test on a board key rings the SoundBoard lane, not a fake notification",
         %{conn: conn} do
      BusterClaw.Notifications.SoundBoard.subscribe()
      {:ok, view, _html} = live(conn, ~p"/notify-settings")

      render_click(view, "test", %{"key" => "confirm"})

      assert_receive {:sound_ring, "confirm"}
      # No notification was fabricated for an event family that never makes one.
      assert Notifications.upcoming(10) == []
    end

    test "the master switch toggles from the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notify-settings")
      assert Sound.enabled?()

      html = render_click(view, "toggle_sound", %{})
      refute Sound.enabled?()
      assert html =~ "Sound off"

      render_click(view, "toggle_sound", %{})
      assert Sound.enabled?()
    end
  end
end
