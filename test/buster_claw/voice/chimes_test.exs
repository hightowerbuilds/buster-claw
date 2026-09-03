defmodule BusterClaw.Voice.ChimesTest do
  # async: false — points the workspace root at a tmp dir, which is where both
  # the sound library and the render cache resolve from.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.Chimes

  setup do
    root = Path.join(System.tmp_dir!(), "bc_chimes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :workspace_root, previous),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "the lines" do
    test "every spoken key is a live routing key, and every line is short" do
      for key <- Chimes.keys() do
        assert key in Sound.route_keys(), "#{key} is not a routing key anything can fire"
        line = Chimes.line(key)
        assert is_binary(line) and line != ""

        # A spoken chime competes with whatever the person is already doing.
        # This is a review-forcing bound, not a style rule: if a line needs to be
        # longer than this, that is worth someone looking at.
        assert String.length(line) <= 40, "#{key}'s line is long enough to talk over: #{line}"
      end
    end

    test "the dead `order` key has no line, because nothing can fire it" do
      # It still has a routing slot, so a naive "one line per route key" would
      # have produced a chime nobody will ever hear.
      assert "order" in Sound.route_keys()
      refute "order" in Chimes.keys()
    end

    test "an edit sticks, and reset puts the seeded line back" do
      original = Chimes.line("timer")

      assert :ok = Chimes.put_line("timer", "Time's up, boss.")
      assert Chimes.line("timer") == "Time's up, boss."
      # Only the edited key moves.
      assert Chimes.line("alarm") == Chimes.defaults()["alarm"]

      assert :ok = Chimes.reset("timer")
      assert Chimes.line("timer") == original
    end

    test "a blank line resets rather than storing an empty chime" do
      assert :ok = Chimes.put_line("alarm", "Custom.")
      assert :ok = Chimes.put_line("alarm", "   ")

      # Silence is expressed by routing a key at nothing, not by a chime that
      # says nothing — an empty line would render an empty WAV.
      assert Chimes.line("alarm") == Chimes.defaults()["alarm"]
    end

    test "reset_all clears every edit at once" do
      assert :ok = Chimes.put_line("timer", "One.")
      assert :ok = Chimes.put_line("alarm", "Two.")

      assert :ok = Chimes.reset_all()

      assert Chimes.lines() == Chimes.defaults()
    end

    test "a key nothing routes is refused on both sides" do
      assert {:error, :unknown_key} = Chimes.put_line("nope", "hello")
      assert {:error, :unknown_key} = Chimes.reset("nope")
      assert {:error, :unknown_key} = Chimes.render("nope")
    end

    test "edits survive a corrupted settings blob rather than crashing" do
      BusterClaw.Settings.put("voice_chime_lines", "not json at all")
      assert Chimes.lines() == Chimes.defaults()
    end
  end

  describe "installing" do
    test "a rendered file becomes the chime for a key, and the key is routed at it", %{root: root} do
      source = Path.join(root, "rendered.wav")
      File.write!(source, wav_bytes())

      assert {:ok, name} = Chimes.install("timer", source)
      assert name == "voice-timer.wav"

      assert File.regular?(Path.join([root, "sounds", "voice-timer.wav"]))
      assert Sound.resolved("timer") == "voice-timer.wav"
      assert Chimes.installed?("timer")

      # And a fired notification resolves to it, which is the only thing that
      # actually matters.
      assert Sound.for_notification(%{source: "timer", kind: "timer"}) == "voice-timer.wav"
    end

    test "re-installing replaces the chime instead of accumulating copies", %{root: root} do
      first = Path.join(root, "first.wav")
      second = Path.join(root, "second.wav")
      File.write!(first, wav_bytes(100))
      File.write!(second, wav_bytes(200))

      assert {:ok, "voice-alarm.wav"} = Chimes.install("alarm", first)
      assert {:ok, "voice-alarm.wav"} = Chimes.install("alarm", second)

      # The library's install_file/2 picks a FREE name, which would have left
      # voice-alarm-2.wav on disk and the old chime still routed. Editing a line
      # and re-rendering has to change what you hear.
      installed = File.ls!(Path.join(root, "sounds")) |> Enum.filter(&(&1 =~ "voice-alarm"))
      assert installed == ["voice-alarm.wav"]

      assert File.read!(Path.join([root, "sounds", "voice-alarm.wav"])) == File.read!(second)
    end

    test "installing something that is not there is refused", %{root: _root} do
      assert {:error, :not_found} = Chimes.install("timer", "/nonexistent/x.wav")
    end

    test "installing against an unroutable key is refused", %{root: root} do
      source = Path.join(root, "r.wav")
      File.write!(source, wav_bytes())

      assert {:error, :unknown_key} = Chimes.install("order", source)
      assert {:error, :unknown_key} = Chimes.install("nope", source)
    end
  end

  defp wav_bytes(ms \\ 100) do
    rate = 22_050
    samples = trunc(rate * ms / 1000)
    data = :binary.copy(<<0::little-signed-16>>, samples)
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end
end
