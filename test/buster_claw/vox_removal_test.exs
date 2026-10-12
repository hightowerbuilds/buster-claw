defmodule BusterClaw.VoxRemovalTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Notifications, Settings, Workspace}
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.Speech

  setup do
    root = Path.join(System.tmp_dir!(), "bc_vox_upgrade_#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      if previous_root do
        Application.put_env(:buster_claw, :workspace_root, previous_root)
      else
        Application.delete_env(:buster_claw, :workspace_root)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "fresh workspace scaffolding keeps speech and ordinary sounds available", %{root: root} do
    assert :ok = Workspace.ensure()
    assert :ok = Sound.ensure()
    refute File.exists?(Path.join(root, "sounds/voice"))
    assert Sound.list() == []
    assert Sound.for_notification(%{source: "manual", kind: "timer"}) == "manual.wav"

    assert Speech.to_spoken("**Ready.** [Open the report](https://example.com)") ==
             "Ready. Open the report"
  end

  test "boot scaffolding preserves completed and partial audio, manifests and saved settings", %{
    root: root
  } do
    %{files: files, settings: settings, pending: pending} = seed_upgrade(root)
    hashes = hashes(root, Map.keys(files))

    # These are the same idempotent scaffolding paths used on application boot
    # and when the operator opens the sound library after an upgrade.
    assert :ok = Workspace.ensure()
    assert :ok = Sound.ensure()
    assert :ok = Workspace.ensure()

    assert hashes(root, Map.keys(files)) == hashes
    assert Settings.get_all() == settings
    assert Notifications.get_notification!(pending.id) == pending
    assert Sound.sound_map() == %{"reminder" => "spoken-reminder.wav"}

    assert Sound.list() == [
             "clip-kept.wav",
             "message-report-done.wav",
             "spoken-reminder.wav"
           ]
  end

  test "a pending spoken notification still fires and falls back if its installed audio disappears",
       %{
         root: root
       } do
    %{pending: pending} = seed_upgrade(root)
    assert :ok = Workspace.ensure()
    assert :ok = Notifications.subscribe()

    assert [fired] = Notifications.fire_due(pending.fire_at)
    assert fired.id == pending.id
    assert fired.status == "fired"
    assert fired.metadata == pending.metadata
    assert_receive {:notification_fired, ^fired}
    assert Sound.for_notification(fired) == "message-report-done.wav"
    assert File.read!(Sound.path_for("message-report-done.wav")) == wav()

    File.rm!(Path.join(root, "sounds/message-report-done.wav"))
    assert Sound.for_notification(fired) == "spoken-reminder.wav"
    assert File.regular?(Path.join(root, "sounds/voice/rendered.wav"))
    assert Notifications.fire_due(pending.fire_at) == []
  end

  defp seed_upgrade(root) do
    files = %{
      "sounds/voice/reference/operator.wav" => wav(),
      "sounds/voice/rendered.wav" => wav(),
      "sounds/voice/unfinished.wav.part" => "partial render kept for the operator",
      "sounds/voice/clips.json" => Jason.encode!([%{text: "Kept phrase", path: "rendered.wav"}]),
      "sounds/voice/messages.json" =>
        Jason.encode!([%{name: "report-done", text: "The report is ready."}]),
      "sounds/message-report-done.wav" => wav(),
      "sounds/clip-kept.wav" => wav(),
      "sounds/spoken-reminder.wav" => wav()
    }

    Enum.each(files, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    for {key, value} <- %{
          "voice_engine_config" => ~s({"device":"cpu","quality":"careful"}),
          "voice_calibration" => ~s({"quality":"careful","elapsed_ms":1234}),
          "voice_chime_lines" => ~s({"reminder":"Your reminder is ready."}),
          "voice_greeting_text" => "Please leave a message.",
          "voice_greeting_published_digest" => "preserved-published-digest"
        } do
      assert {:ok, _} = Settings.put(key, value)
    end

    assert :ok = Sound.assign("reminder", "spoken-reminder.wav")

    assert {:ok, pending} =
             Notifications.create_notification(%{
               kind: "reminder",
               label: "The report is ready.",
               fire_at:
                 DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
               metadata: %{
                 "sound" => "message-report-done.wav",
                 "voice_message" => "report-done"
               }
             })

    %{files: files, settings: Settings.get_all(), pending: pending}
  end

  defp hashes(root, paths) do
    Map.new(paths, fn relative ->
      bytes = File.read!(Path.join(root, relative))
      {relative, :crypto.hash(:sha256, bytes)}
    end)
  end

  defp wav do
    rate = 22_050
    data = :binary.copy(<<1000::little-signed-16>>, div(rate, 10))
    length = byte_size(data)

    <<"RIFF", 36 + length::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data",
      length::little-32, data::binary>>
  end
end
