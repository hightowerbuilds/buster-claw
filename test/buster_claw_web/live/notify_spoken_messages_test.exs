defmodule BusterClawWeb.NotifySpokenMessagesTest do
  @moduledoc """
  The "Spoken messages" panel on Settings → Notify. Needs a stub engine and a
  scratch workspace, both global, so `async: false` and kept apart from the
  page's other tests.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications
  alias BusterClaw.Voice.{Engine, Messages, Renderer}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_nmsg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))
    previous_root = Application.get_env(:buster_claw, :workspace_root)
    previous_path = Application.get_env(:buster_claw, :voxcpm_path)
    previous_device = Application.get_env(:buster_claw, :voxcpm_device)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :voxcpm_device, "cpu")

    on_exit(fn ->
      restore(:workspace_root, previous_root)
      restore(:voxcpm_path, previous_path)
      restore(:voxcpm_device, previous_device)
      Engine.refresh()
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "the panel is there, and says how the agent reaches it", %{conn: conn} do
    absent()
    {:ok, _view, html} = live(conn, ~p"/notify-settings")

    assert html =~ "Spoken messages"
    assert html =~ ~s(name="message[name]")
    assert html =~ ~s(name="message[text]")
    assert html =~ "voice_message_create"
  end

  test "with no engine, making one says where to get an engine", %{conn: conn} do
    absent()
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    html =
      view
      |> form("form[phx-submit=message_create]", %{"message" => %{"name" => "x", "text" => "Hi."}})
      |> render_submit()

    assert html =~ "No speech engine"
    assert Messages.list() == []
  end

  test "make → it appears as making, lands as ready with a preview, fires as a notification",
       %{conn: conn, root: root} do
    stub(root)
    {:ok, view, _html} = live(conn, ~p"/notify-settings")

    html =
      view
      |> form("form[phx-submit=message_create]", %{
        "message" => %{"name" => "Stand up", "text" => "Stand up and stretch."}
      })
      |> render_submit()

    assert html =~ "stand-up"
    assert html =~ "Making"

    # The render lands, the renderer broadcasts, the page re-lists — and installs
    # the sound on the way past, so the preview URL is a real library file.
    # The specific URL, not the word "Preview" — the chime rows above already say
    # that, so a looser wait returns before this message has landed.
    assert eventually(fn ->
             render(view) =~ ~s(data-preview-url="/notify/sound/message-stand-up.wav")
           end),
           "expected the message to become ready with a preview"

    assert File.regular?(Path.join([root, "sounds", "message-stand-up.wav"]))

    html =
      view
      |> element("button[phx-click=message_fire][phx-value-name=stand-up]", "Fire now")
      |> render_click()

    assert html =~ "Fired."

    notification =
      Enum.find(Notifications.list_notifications(), &(&1.label == "Stand up and stretch."))

    assert notification, "firing must create a real notification row"
    assert notification.metadata["sound"] == "message-stand-up.wav"
  end

  test "delete removes it from the page and the library", %{conn: conn, root: root} do
    stub(root)
    Renderer.subscribe()
    {:ok, %{path: path}} = Messages.create("gone", "Going.")
    assert_receive {:voice_render, _, {:ok, ^path}}, 5_000

    {:ok, view, html} = live(conn, ~p"/notify-settings")
    assert html =~ "gone"

    html =
      view |> element("button[phx-click=message_delete][phx-value-name=gone]") |> render_click()

    refute html =~ ~s(phx-value-name="gone")
    refute File.exists?(Path.join([root, "sounds", "message-gone.wav"]))
  end

  defp absent do
    Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
    Engine.refresh()
  end

  defp stub(root) do
    fixture = Path.join(root, "fixture.wav")
    File.write!(fixture, wav())
    path = Path.join(root, "voxcpm-stub")

    File.write!(
      path,
      "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"--output\" ]; then out=\"$2\"; fi\n  shift\ndone\ncp \"#{fixture}\" \"$out\"\nexit 0\n"
    )

    File.chmod!(path, 0o755)
    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
  end

  defp wav do
    rate = 22_050
    data = :binary.copy(<<0::little-signed-16>>, div(rate, 10))
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(),
        do: {:halt, true},
        else:
          (
            Process.sleep(20)
            {:cont, false}
          )
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
