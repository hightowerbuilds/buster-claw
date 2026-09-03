defmodule BusterClaw.Commands.VoiceMessageTest do
  @moduledoc """
  The four spoken-message verbs, driven through `Commands.call/3` BY NAME — the
  same discipline as the sound acceptance walk: a handler nothing can reach
  through the dispatcher is not a command surface, and this fails on a missing
  catalog entry, a missing registration and a missing delegate exactly as loudly
  as on a wrong answer.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Voice.{Engine, Renderer}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_vmcmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))
    previous_root = Application.get_env(:buster_claw, :workspace_root)
    previous_path = Application.get_env(:buster_claw, :voxcpm_path)
    previous_device = Application.get_env(:buster_claw, :voxcpm_device)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :voxcpm_device, "cpu")

    fixture = Path.join(root, "fixture.wav")
    File.write!(fixture, wav())
    stub = Path.join(root, "voxcpm-stub")

    File.write!(
      stub,
      "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"--output\" ]; then out=\"$2\"; fi\n  shift\ndone\ncp \"#{fixture}\" \"$out\"\nexit 0\n"
    )

    File.chmod!(stub, 0o755)
    Application.put_env(:buster_claw, :voxcpm_path, stub)
    Engine.refresh()

    on_exit(fn ->
      restore(:workspace_root, previous_root)
      restore(:voxcpm_path, previous_path)
      restore(:voxcpm_device, previous_device)
      Engine.refresh()
      File.rm_rf(root)
    end)

    Renderer.subscribe()
    :ok
  end

  test "the agent can leave the operator a message in the operator's voice, end to end" do
    # 1. Create. Returns before the engine has finished.
    assert {:ok, %{name: "report-done", ready?: false}} =
             Commands.call("voice_message_create", %{
               "name" => "Report done",
               "text" => "I finished the report you asked for."
             })

    assert_receive {:voice_render, _key, {:ok, _path}}, 5_000

    # 2. List shows it landed.
    assert {:ok, %{count: 1, messages: [%{name: "report-done", ready?: true}]}} =
             Commands.call("voice_message_list", %{})

    # 3. Fire: a real notification, labelled with the words, carrying the sound.
    assert {:ok, notification} = Commands.call("voice_message_fire", %{"name" => "report-done"})
    assert notification.label == "I finished the report you asked for."
    assert notification.metadata["sound"] == "message-report-done.wav"

    # 4. And it can be scheduled the way notify_create schedules.
    assert {:ok, %{kind: "timer"}} =
             Commands.call("voice_message_fire", %{"name" => "report-done", "in_seconds" => 120})

    # 5. Delete.
    assert {:ok, %{deleted: "report-done"}} =
             Commands.call("voice_message_delete", %{"name" => "report-done"})

    assert {:ok, %{count: 0}} = Commands.call("voice_message_list", %{})
  end

  test "refusals are named, not raised" do
    assert {:error, :missing_name} = Commands.call("voice_message_create", %{"text" => "x"})
    assert {:error, :missing_text} = Commands.call("voice_message_create", %{"name" => "x"})

    assert {:error, :invalid_name} =
             Commands.call("voice_message_create", %{"name" => "!!", "text" => "x"})

    assert {:error, :not_found} = Commands.call("voice_message_fire", %{"name" => "nope"})
    assert {:error, :not_found} = Commands.call("voice_message_delete", %{"name" => "nope"})
  end

  test "the catalog agrees with the handlers: every verb has an entry with a type and tier" do
    for verb <-
          ~w(voice_message_create voice_message_list voice_message_fire voice_message_delete) do
      assert Commands.command_type(verb) != nil, "#{verb} is not in the catalog"
    end

    assert Commands.command_type("voice_message_list") == :read
    assert Commands.command_type("voice_message_fire") == :mutate
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
