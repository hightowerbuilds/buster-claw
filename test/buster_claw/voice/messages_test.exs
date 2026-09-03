defmodule BusterClaw.Voice.MessagesTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.{Engine, Messages, Renderer}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_msgs_#{System.unique_integer([:positive])}")
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

    Renderer.subscribe()
    {:ok, root: root}
  end

  describe "names" do
    test "a human name becomes a slug, and junk is refused" do
      assert {:ok, "stand-up"} = Messages.slug("Stand Up")
      assert {:ok, "meds-9am"} = Messages.slug("  meds_9am ")
      assert {:error, :invalid_name} = Messages.slug("!!!")
      assert {:error, :invalid_name} = Messages.slug("")
      assert {:error, :invalid_name} = Messages.slug(nil)
    end
  end

  describe "create" do
    test "returns at once, not ready, and becomes ready when the render lands", %{root: root} do
      stub(root)

      assert {:ok, row} = Messages.create("Stand up", "Stand up and stretch.")
      assert row.name == "stand-up"
      assert row.text == "Stand up and stretch."
      assert row.sound == "message-stand-up.wav"
      refute row.ready?
      refute row.installed?

      path = row.path
      assert_receive {:voice_render, _key, {:ok, ^path}}, 5_000

      # Readiness is read off the disk, not tracked — nothing was listening.
      assert %{ready?: true, installed?: false} = Messages.get("stand-up")
    end

    test "the same name replaces, so a message can be re-worded", %{root: root} do
      stub(root)
      assert {:ok, _} = Messages.create("meds", "Take your pills.")
      assert {:ok, _} = Messages.create("meds", "Take your medication.")

      assert [%{name: "meds", text: "Take your medication."}] = Messages.list()
    end

    test "empty text, a bad name and a missing engine are refused before anything is written",
         %{root: _root} do
      Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
      Engine.refresh()

      assert {:error, :engine_unavailable} = Messages.create("ok", "hello")
      assert {:error, :empty_text} = Messages.create("ok", "   ")
      assert {:error, :invalid_name} = Messages.create("???", "hello")
      assert Messages.list() == []
    end
  end

  describe "installing and firing" do
    test "a ready message installs into the sound library, once", %{root: root} do
      stub(root)
      # Pinned to OUR path: the renderer's topic is global, and a broadcast from
      # a previous test's render landing late would otherwise satisfy this.
      {:ok, %{path: path}} = Messages.create("done", "The build is done.")
      assert_receive {:voice_render, _key, {:ok, ^path}}, 5_000

      assert {:ok, "message-done.wav"} = Messages.ensure_installed("done")
      assert "message-done.wav" in Sound.list()
      assert File.regular?(Path.join([root, "sounds", "message-done.wav"]))

      # Idempotent — a second call copies nothing and still answers.
      assert {:ok, "message-done.wav"} = Messages.ensure_installed("done")
      assert %{installed?: true} = Messages.get("done")
    end

    test "firing creates a notification whose sound is the message, and the resolver honours it",
         %{root: root} do
      stub(root)
      # Pinned to OUR path: the renderer's topic is global, and a broadcast from
      # a previous test's render landing late would otherwise satisfy this.
      {:ok, %{path: path}} = Messages.create("done", "The build is done.")
      assert_receive {:voice_render, _key, {:ok, ^path}}, 5_000

      assert {:ok, notification} = Messages.fire("done")

      assert notification.kind == "reminder"
      assert notification.label == "The build is done."
      assert notification.metadata["sound"] == "message-done.wav"
      assert notification.metadata["voice_message"] == "done"

      # The one-clause change in Sound: the message's own sound beats the
      # routing walk, so a reminder routed at "alarm.wav" still says the words.
      assert :ok = Sound.assign("reminder", "alarm.wav")
      assert Sound.for_notification(notification) == "message-done.wav"
    end

    test "a message whose sound was deleted falls back to the routing walk, not silence",
         %{root: root} do
      stub(root)
      # Pinned to OUR path: the renderer's topic is global, and a broadcast from
      # a previous test's render landing late would otherwise satisfy this.
      {:ok, %{path: path}} = Messages.create("done", "The build is done.")
      assert_receive {:voice_render, _key, {:ok, ^path}}, 5_000
      {:ok, notification} = Messages.fire("done")

      File.rm!(Path.join([root, "sounds", "message-done.wav"]))

      # Something still rings — a dangling name must not mute the notification.
      assert Sound.for_notification(notification) != nil
      refute Sound.for_notification(notification) == "message-done.wav"
    end

    test "in_seconds makes a timer and at makes an alarm", %{root: root} do
      stub(root)
      {:ok, %{path: path}} = Messages.create("later", "Later.")
      assert_receive {:voice_render, _key, {:ok, ^path}}, 5_000

      assert {:ok, %{kind: "timer"} = timer} = Messages.fire("later", %{"in_seconds" => 90})
      assert DateTime.diff(timer.fire_at, DateTime.utc_now()) in 85..95

      at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      assert {:ok, %{kind: "alarm"}} = Messages.fire("later", %{"at" => at})
      assert {:error, :invalid_at} = Messages.fire("later", %{"at" => "tomorrow-ish"})
    end

    test "firing before the render has landed is refused, and names why", %{root: root} do
      slow_stub(root)
      {:ok, _} = Messages.create("slow", "Slow line.")

      assert {:error, :not_ready} = Messages.fire("slow")
      assert {:error, :not_found} = Messages.fire("nope")
    end

    test "delete removes the row and the library sound, and leaves the cache", %{root: root} do
      stub(root)
      {:ok, %{path: path} = row} = Messages.create("gone", "Going.")
      assert_receive {:voice_render, _key, {:ok, ^path}}, 5_000
      {:ok, _} = Messages.ensure_installed("gone")

      assert :ok = Messages.delete("gone")
      assert Messages.list() == []
      refute "message-gone.wav" in Sound.list()
      assert File.regular?(row.path), "the render cache owns its file"
      assert {:error, :not_found} = Messages.delete("gone")
    end
  end

  test "fired messages are real notifications — they show up in the pending list" do
    # No engine needed for this: create the row by hand as a ready message.
    Renderer.ensure()
    {:ok, path} = Renderer.path_for("Hand made.")
    File.write!(path, wav())
    File.mkdir_p!(Sound.dir())
    File.cp!(path, Path.join(Sound.dir(), "message-hand.wav"))

    {:ok, notification} =
      Notifications.create_notification(%{
        "kind" => "timer",
        "label" => "Hand made.",
        "fire_at" =>
          DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second),
        "status" => "pending",
        "source" => "manual",
        "metadata" => %{"sound" => "message-hand.wav"}
      })

    assert notification.id in Enum.map(Notifications.list_notifications(), & &1.id)
  end

  defp stub(root) do
    install_stub(root, "cp \"#{fixture(root)}\" \"$out\"\nexit 0\n")
  end

  # Never writes the output: the render "never lands", so readiness stays false.
  defp slow_stub(root) do
    install_stub(root, "exit 0\n")
  end

  defp install_stub(root, tail) do
    path = Path.join(root, "voxcpm-stub")

    preamble = """
    #!/bin/sh
    out=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--output" ]; then out="$2"; fi
      shift
    done
    """

    File.write!(path, preamble <> tail)

    File.chmod!(path, 0o755)
    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
  end

  defp fixture(root) do
    f = Path.join(root, "fixture.wav")
    File.write!(f, wav())
    f
  end

  defp wav do
    rate = 22_050
    data = :binary.copy(<<0::little-signed-16>>, div(rate, 10))
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
