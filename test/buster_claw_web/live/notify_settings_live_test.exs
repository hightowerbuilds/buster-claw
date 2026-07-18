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
    # Library lists both seeded sounds; routing rows are present.
    assert html =~ "bongos.wav"
    assert html =~ "wilhelm.wav"
    assert html =~ "Voicemail"
    assert html =~ ~s(phx-hook="SoundPreview")
  end

  test "assigning a sound to an event persists the routing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    view
    |> form("#assign-voicemail", %{"sound" => "wilhelm.wav"})
    |> render_change()

    assert Sound.sound_map() == %{"voicemail" => "wilhelm.wav"}
    assert render(view) =~ "plays: Wilhelm"
  end

  test "an invalid assignment is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    render_change(view, "assign", %{"key" => "voicemail", "sound" => "missing.wav"})

    assert Sound.sound_map() == %{}
    assert render(view) =~ "Couldn&#39;t save that routing."
  end

  test "Test fires a real notification carrying the row's kind and source", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    render_click(view, "test", %{"key" => "voicemail"})

    assert [notification] = Notifications.list_notifications()
    assert notification.kind == "reminder"
    assert notification.source == "voicemail"
    assert notification.label == "Notify test — Voicemail"
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
end
