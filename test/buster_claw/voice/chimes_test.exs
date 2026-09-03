defmodule BusterClaw.Voice.ChimesTest do
  # async: false — points the workspace root at a tmp dir, which is where both
  # the sound library and the render cache resolve from.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.Chimes
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Renderer

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

  describe "render_set/1 — the whole set in one model load" do
    setup do
      previous_path = Application.get_env(:buster_claw, :voxcpm_path)
      previous_device = Application.get_env(:buster_claw, :voxcpm_device)

      on_exit(fn ->
        if previous_path,
          do: Application.put_env(:buster_claw, :voxcpm_path, previous_path),
          else: Application.delete_env(:buster_claw, :voxcpm_path)

        if previous_device,
          do: Application.put_env(:buster_claw, :voxcpm_device, previous_device),
          else: Application.delete_env(:buster_claw, :voxcpm_device)

        Engine.refresh()
      end)

      Application.put_env(:buster_claw, :voxcpm_device, "cpu")

      # These tests reason about what is and is not in the cache, so the cache
      # must start empty — assert the precondition rather than assume it. Seen
      # once on 09-03-26 (random seed, not reproduced in five more runs): the gap
      # test found its victim line already cached, so it read {:ok, _} where
      # :not_rendered was expected. The likely leak is `workspace_root`, which is
      # global app env: a render from another test that finishes after that test
      # has ended computes its cache path from whatever root is current, and
      # writes a chime line into this test's directory. Wiping here closes that
      # hole whatever its exact source.
      File.rm_rf!(Renderer.cache_dir())
      :ok
    end

    test "every key gets the output at its own position", %{root: root} do
      batch_stub(root, skip: [])

      assert {:ok, results} = Chimes.render_set()
      assert length(results) == length(Chimes.keys())

      # Order is the contract: keys() order in, output_NNN.wav order out.
      assert Enum.map(results, &elem(&1, 0)) == Chimes.keys()

      for {_key, result} <- results, do: assert({:ok, _path} = result)
    end

    test "a line the engine failed on leaves a GAP, and never shifts the rest", %{root: root} do
      # This is the property the whole positional mapping rests on. voxcpm's loop
      # advances its counter even when a line raises, so a failure means
      # output_005.wav is simply absent — not that output_006 slid down into its
      # place. If it shifted, a timer would play "Security event."
      keys = Chimes.keys()
      victim_index = 5
      victim_key = Enum.at(keys, victim_index - 1)

      batch_stub(root, skip: [victim_index])

      assert {:ok, results} = Chimes.render_set()

      assert {^victim_key, {:error, :not_rendered}} = Enum.at(results, victim_index - 1)

      # Everything after the hole still maps to its own key.
      for {key, result} <- results, key != victim_key do
        assert {:ok, path} = result
        assert File.regular?(path)
      end
    end

    test "an empty output file is a failure, not a silent chime", %{root: root} do
      batch_stub(root, empty: [3])

      assert {:ok, results} = Chimes.render_set()
      key = Enum.at(Chimes.keys(), 2)

      # A zero-byte WAV would install happily and play nothing at all.
      assert {^key, {:error, :not_rendered}} = Enum.at(results, 2)
    end

    test "a second run makes nothing — the set is already in the cache", %{root: root} do
      counter = Path.join(root, "invocations")
      batch_stub(root, skip: [], counter: counter)

      assert {:ok, first} = Chimes.render_set()
      assert File.read!(counter) |> String.trim() |> String.length() == 1

      assert {:ok, second} = Chimes.render_set()

      # The engine was NOT run again. On this hardware the difference between a
      # cache hit and a re-render is about forty minutes, so "press it twice"
      # must not mean "wait twice".
      assert File.read!(counter) |> String.trim() |> String.length() == 1
      assert Enum.map(first, &elem(&1, 0)) == Enum.map(second, &elem(&1, 0))

      for {a, b} <- Enum.zip(first, second), do: assert(a == b)
    end

    test "only the lines that changed are re-rendered", %{root: root} do
      counter = Path.join(root, "invocations")
      batch_stub(root, skip: [], counter: counter)
      assert {:ok, _} = Chimes.render_set()

      # Change exactly one line. The batch that follows must carry one line, not
      # sixteen — that is the whole reason the cache is consulted first.
      assert :ok = Chimes.put_line("timer", "Time is up, entirely.")
      assert {:ok, results} = Chimes.render_set()

      assert File.read!(Path.join(root, "last_input_lines")) |> String.trim() == "1"
      assert {"timer", {:ok, _}} = Enum.find(results, fn {k, _} -> k == "timer" end)
    end

    test "with no engine it refuses rather than writing a temp file" do
      Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
      Engine.refresh()

      assert {:error, :engine_unavailable} = Chimes.render_set()
    end

    test "a non-zero exit is reported with its output", %{root: root} do
      failing_stub(root)

      assert {:error, {:exit, 4, output}} = Chimes.render_set()
      assert output =~ "out of memory"
    end
  end

  # A stub that behaves the way voxcpm's `batch` actually does: read --input,
  # write output_NNN.wav into --output-dir, numbered from 1 by line position.
  defp batch_stub(root, opts) do
    fixture = Path.join(root, "batch-fixture.wav")
    File.write!(fixture, wav_bytes())

    skip = Enum.map_join(opts[:skip] || [], " ", &to_string/1)
    empty = Enum.map_join(opts[:empty] || [], " ", &to_string/1)
    counter = opts[:counter] || Path.join(root, "invocations")
    seen = Path.join(root, "last_input_lines")

    script = """
    #!/bin/sh
    outdir=""
    inp=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--output-dir" ]; then outdir="$2"; fi
      if [ "$1" = "--input" ]; then inp="$2"; fi
      shift
    done
    printf 'x' >> "#{counter}"
    grep -c . "$inp" > "#{seen}"
    i=1
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      n=$(printf '%03d' $i)
      skipped=0
      for s in #{skip}; do [ "$s" = "$i" ] && skipped=1; done
      for e in #{empty}; do [ "$e" = "$i" ] && : > "$outdir/output_$n.wav" && skipped=1; done
      [ $skipped -eq 0 ] && cp "#{fixture}" "$outdir/output_$n.wav"
      i=$((i+1))
    done < "$inp"
    exit 0
    """

    install(root, script)
  end

  defp failing_stub(root) do
    install(root, "#!/bin/sh\necho 'voxcpm: out of memory' >&2\nexit 4\n")
  end

  defp install(root, script) do
    path = Path.join(root, "voxcpm-batch-stub")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
    path
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
