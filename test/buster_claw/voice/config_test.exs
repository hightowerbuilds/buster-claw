defmodule BusterClaw.Voice.ConfigTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Voice.{Chimes, Config, Engine, Greeting}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_vcfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))
    previous_root = Application.get_env(:buster_claw, :workspace_root)
    previous_device = Application.get_env(:buster_claw, :voxcpm_device)
    previous_path = Application.get_env(:buster_claw, :voxcpm_path)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :voxcpm_device, "cpu")

    on_exit(fn ->
      restore(:workspace_root, previous_root)
      restore(:voxcpm_device, previous_device)
      restore(:voxcpm_path, previous_path)
      Engine.refresh()
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "storing" do
    test "empty is the engine's defaults, and changes nothing about a render" do
      assert Config.get().device == nil
      assert Config.render_opts() == []
      refute Config.cloning?()
    end

    test "blank clears, values stick, unknown keys are ignored" do
      assert :ok = Config.put(%{"device" => "mps", "control" => "warm, low", "bogus" => "x"})
      assert Config.get().device == "mps"
      assert Config.get().control == "warm, low"

      assert :ok = Config.put(%{"device" => "  "})
      assert Config.get().device == nil
      # Untouched keys survive a partial put.
      assert Config.get().control == "warm, low"
    end

    test "reset clears everything" do
      assert :ok = Config.put(%{"control" => "bright"})
      assert :ok = Config.reset()
      assert Config.get() |> Map.values() |> Enum.all?(&is_nil/1)
    end

    test "a corrupted settings blob reads as defaults rather than crashing" do
      BusterClaw.Settings.put("voice_engine_config", "{not json")
      assert Config.render_opts() == []
    end
  end

  describe "validation — the shapes the engine will accept" do
    test "device is cpu, mps, cuda or cuda:N and nothing else" do
      for ok <- ~w(cpu mps cuda cuda:0 cuda:3),
          do: assert(:ok = Config.put(%{"device" => ok}), ok)

      assert {:error, {:device, "gpu"}} = Config.put(%{"device" => "gpu"})
      assert {:error, {:device, "cuda:x"}} = Config.put(%{"device" => "cuda:x"})
    end

    test "a reference clip must be a real file, and is stored expanded", %{root: root} do
      clip = Path.join(root, "me.wav")
      File.write!(clip, "RIFF....")

      assert :ok = Config.put(%{"reference_audio" => clip})
      assert Config.get().reference_audio == clip
      assert Config.cloning?()

      # Pointing at nothing is refused rather than stored — a clone of a missing
      # file is a silent fall-back to a stranger's voice.
      assert {:error, {:reference_audio, :not_found}} =
               Config.put(%{"reference_audio" => Path.join(root, "gone.wav")})

      assert Config.get().reference_audio == clip, "a refused put must not clobber the good value"
    end

    test "steps are a positive integer, guidance a positive number" do
      assert :ok = Config.put(%{"inference_timesteps" => "12", "cfg_value" => "2.5"})
      assert Config.get().inference_timesteps == 12
      assert Config.get().cfg_value == 2.5

      assert {:error, {:inference_timesteps, "0"}} = Config.put(%{"inference_timesteps" => "0"})

      assert {:error, {:inference_timesteps, "ten"}} =
               Config.put(%{"inference_timesteps" => "ten"})

      assert {:error, {:cfg_value, "-1"}} = Config.put(%{"cfg_value" => "-1"})
    end
  end

  describe "reaching the engine" do
    test "render_opts is exactly what Engine's builders take", %{root: root} do
      clip = Path.join(root, "me.wav")
      File.write!(clip, "RIFF....")

      assert :ok =
               Config.put(%{
                 "device" => "cuda:1",
                 "reference_audio" => clip,
                 "inference_timesteps" => "8",
                 "cfg_value" => "1.5"
               })

      opts = Config.render_opts()
      args = Engine.clone_args("hi", "/tmp/o.wav", opts[:reference_audio], opts)

      assert_pair(args, "--device", "cuda:1")
      assert_pair(args, "--reference-audio", clip)
      assert_pair(args, "--inference-timesteps", "8")
      assert_pair(args, "--cfg-value", "1.5")
    end

    test "a stored engine path is found after the app-env override, and not before", %{root: root} do
      stub = Path.join(root, "voxcpm-from-settings")
      File.write!(stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(stub, 0o755)

      assert :ok = Config.put(%{"engine_path" => stub})
      Application.delete_env(:buster_claw, :voxcpm_path)
      assert Engine.refresh().path == stub

      # The app-env override is still authoritative — tests and config files pin
      # it, and a settings row must not be able to redirect that.
      Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
      refute Engine.refresh().available?
    end

    test "changing the voice makes every made chime a miss", %{root: root} do
      # Made under the defaults…
      for key <- Chimes.keys() do
        {:ok, path} = BusterClaw.Voice.Renderer.path_for(Chimes.line(key))
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, :binary.copy(<<0>>, 100))
      end

      assert {16, 16} = Chimes.made_count()

      # …and a reference clip is a different ask for every one of them. This is
      # the number the settings page shows, and it is meant to hurt a little.
      clip = Path.join(root, "me.wav")
      File.write!(clip, "RIFF....")
      assert :ok = Config.put(%{"reference_audio" => clip})

      assert {0, 16} = Chimes.made_count()
    end

    test "changing the voice marks a published greeting stale", %{root: root} do
      # RESTORE, never delete. These keys are set in config/test.exs for the
      # telephony suites; deleting them here wiped the relay config for every
      # Pins and Drain test that ran after this one — 25 failures in files this
      # test never touched, all reading {:error, :not_configured}.
      previous_url = Application.get_env(:buster_claw, :telephony_relay_url)
      previous_key = Application.get_env(:buster_claw, :telephony_relay_key)
      Application.put_env(:buster_claw, :telephony_relay_url, "https://relay.test")
      Application.put_env(:buster_claw, :telephony_relay_key, "k")

      on_exit(fn ->
        restore(:telephony_relay_url, previous_url)
        restore(:telephony_relay_key, previous_key)
      end)

      audio = Path.join(root, "g.wav")
      File.write!(audio, :binary.copy(<<0>>, 100))
      relay = [req_options: [plug: {Req.Test, __MODULE__}]]

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, _b, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert :ok = Greeting.publish(audio, relay)
      refute Greeting.status(relay).stale?

      # Same words, different voice: callers hear the OLD voice until republished.
      clip = Path.join(root, "me.wav")
      File.write!(clip, "RIFF....")
      assert :ok = Config.put(%{"reference_audio" => clip})

      assert Greeting.status(relay).stale?
    end
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)

  defp assert_pair(args, flag, value) do
    index = Enum.find_index(args, &(&1 == flag))
    assert index, "expected #{flag} in #{inspect(args)}"
    assert Enum.at(args, index + 1) == value
  end
end
