defmodule BusterClaw.Studio.EditorTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Studio.Editor

  # afconvert is a macOS system binary, but the suite should not fail on a
  # machine that lacks it — the decode tests define themselves out instead.
  @decoder_available File.regular?("/usr/bin/afconvert")

  # A clip from a list of int16 samples, at the internal format.
  defp clip(samples) do
    %Editor{data: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)}
  end

  defp samples(%Editor{data: data}), do: for(<<s::little-signed-16 <- data>>, do: s)

  describe "parse/1 and render/1" do
    test "every bundled chime survives a parse/render round trip byte-identically" do
      for key <- SoundGen.keys() do
        original = SoundGen.render(key)
        assert {:ok, parsed} = Editor.parse(original)

        assert Editor.render(parsed) == original,
               "#{key}: round trip changed the bytes"
      end
    end

    test "a parsed chime reports the internal format" do
      assert {:ok, parsed} = Editor.parse(SoundGen.render("boot"))
      assert Editor.internal?(parsed)
      assert {22_050, 1, 16} == Editor.internal_format()
    end

    test "the data chunk is found past intervening chunks, not at a fixed offset" do
      # A LIST chunk of ODD size ahead of the data — this is the shape afconvert
      # is entitled to emit, and the shape a seek-to-byte-44 parser reads as audio.
      # Deliberately ODD (9 bytes), so the chunk carries a pad byte the parser
      # must skip without mistaking it for the next chunk's id.
      list_body = "INFOhello"
      audio = for s <- [1, -1, 2, -2], into: <<>>, do: <<s::little-signed-16>>

      binary =
        <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
          22_050::little-32, 44_100::little-32, 2::little-16, 16::little-16>> <>
          <<"LIST", byte_size(list_body)::little-32>> <>
          list_body <>
          <<0>> <>
          <<"data", byte_size(audio)::little-32>> <> audio

      assert {:ok, parsed} = Editor.parse(binary)
      assert samples(parsed) == [1, -1, 2, -2]
    end

    test "refuses things that are not WAVs, and lying chunk lengths" do
      assert {:error, :not_a_wav} = Editor.parse("this is a text file, not audio")
      assert {:error, :not_a_wav} = Editor.parse(<<>>)

      truncated =
        <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
          22_050::little-32, 44_100::little-32, 2::little-16, 16::little-16>> <>
          <<"data", 9_999::little-32, 0, 0>>

      assert {:error, :malformed_wav} = Editor.parse(truncated)
    end
  end

  describe "splice/3 — the boundary arithmetic" do
    # 1000 samples at 22050 Hz. Sample N holds value N, so a splice's exact
    # first and last sample are readable off the result.
    setup do: %{ramp: clip(Enum.to_list(0..999))}

    test "is half-open: `from` is included, `to` is excluded", %{ramp: ramp} do
      # 0..99 inclusive == 100 samples, at 22050 Hz that is 0 to ~4.535 ms.
      to_ms = 100 * 1000 / 22_050
      assert {:ok, cut} = Editor.splice(ramp, 0, to_ms)

      got = samples(cut)
      assert length(got) == 100
      assert List.first(got) == 0
      assert List.last(got) == 99, "the `to` sample leaked into the selection"
    end

    test "adjacent cuts tile exactly — no repeated sample at the seam", %{ramp: ramp} do
      mid = 500 * 1000 / 22_050
      total = 1000 * 1000 / 22_050

      assert {:ok, a} = Editor.splice(ramp, 0, mid)
      assert {:ok, b} = Editor.splice(ramp, mid, total)
      assert {:ok, joined} = Editor.concat([a, b])

      # If the end were inclusive, sample 500 would appear twice and this would
      # be 1001 samples with an audible step at the join.
      assert samples(joined) == samples(ramp)
    end

    test "clamps out-of-range selections instead of raising", %{ramp: ramp} do
      assert {:ok, cut} = Editor.splice(ramp, -500, 999_999)
      assert samples(cut) == samples(ramp)
    end

    test "refuses an empty or inverted selection", %{ramp: ramp} do
      assert {:error, :empty_selection} = Editor.splice(ramp, 5, 5)
      assert {:error, :empty_selection} = Editor.splice(ramp, 8, 2)
    end
  end

  describe "fade/2" do
    test "lands on true zero at both edges" do
      flat = clip(List.duplicate(10_000, 500))
      ms = 100 * 1000 / 22_050

      faded = Editor.fade(flat, in_ms: ms, out_ms: ms)
      got = samples(faded)

      assert List.first(got) == 0, "fade-in did not start from silence"
      assert List.last(got) == 0, "fade-out did not reach silence"
      # The untouched middle keeps full amplitude.
      assert Enum.at(got, 250) == 10_000
    end

    test "is monotonic across the ramp — no bumps on the way up" do
      flat = clip(List.duplicate(10_000, 500))
      ms = 100 * 1000 / 22_050
      ramp = faded_head(Editor.fade(flat, in_ms: ms), 100)

      assert ramp == Enum.sort(ramp)
      assert List.last(ramp) <= 10_000
    end

    test "ramps longer than the clip are clamped, not an error" do
      flat = clip(List.duplicate(10_000, 100))
      faded = Editor.fade(flat, in_ms: 10_000, out_ms: 10_000)

      assert length(samples(faded)) == 100
      assert Enum.all?(samples(faded), &(abs(&1) <= 10_000))
    end

    test "a zero-length or single-sample ramp is a no-op, not a silencer" do
      flat = clip(List.duplicate(10_000, 50))
      assert samples(Editor.fade(flat, in_ms: 0, out_ms: 0)) == samples(flat)
    end

    defp faded_head(clip, n), do: clip |> samples() |> Enum.take(n)
  end

  describe "normalize/2" do
    test "brings a quiet clip up to the target" do
      quiet = clip([1_000, -1_000, 500])
      normalized = Editor.normalize(quiet)

      assert_in_delta Editor.peak(normalized), 0.891, 0.001
    end

    test "never clips — not even from int16's extra-loud negative rail" do
      # -32768 has no positive counterpart; scaling it naively overflows to a
      # full-scale sign flip, the loudest artifact a sample can produce.
      hot = clip([-32_768, 32_767, -32_768])

      for target <- [0.5, 0.891, 1.0] do
        got = samples(Editor.normalize(hot, target))
        assert Enum.all?(got, &(&1 >= -32_768 and &1 <= 32_767))
      end
    end

    test "silence is returned untouched rather than divided by zero" do
      silence = clip(List.duplicate(0, 64))
      assert samples(Editor.normalize(silence)) == samples(silence)
    end

    test "an empty clip does not crash the gain calculation" do
      assert samples(Editor.normalize(clip([]))) == []
    end
  end

  describe "mixdown/1 — the arrangement render" do
    test "places a clip at its offset, padding the gap with silence" do
      one = clip([9_000, 9_000])
      # 22050 samples == 1000 ms, so a 1000 ms offset is exactly 22050 zeros.
      assert {:ok, mixed} = Editor.mixdown([{one, 1_000}])

      got = samples(mixed)
      assert length(got) == 22_052
      assert Enum.take(got, 22_050) |> Enum.all?(&(&1 == 0))
      assert Enum.drop(got, 22_050) == [9_000, 9_000]
    end

    test "overlapping clips ADD — this is a mix, not a join" do
      a = clip([1_000, 1_000, 1_000])
      b = clip([500, 500, 500])

      assert {:ok, mixed} = Editor.mixdown([{a, 0}, {b, 0}])
      assert samples(mixed) == [1_500, 1_500, 1_500]
    end

    test "the result runs from zero to the furthest clip's end" do
      short = clip(List.duplicate(100, 10))
      assert {:ok, mixed} = Editor.mixdown([{short, 500}, {short, 0}])

      # Furthest edge is 500 ms + 10 samples.
      assert Editor.sample_count(mixed) == 11_025 + 10
    end

    test "a summed overload clamps instead of wrapping" do
      # Four loud clips on the same beat is exactly how an arrangement clips.
      hot = clip([30_000, -30_000])
      placements = for _ <- 1..4, do: {hot, 0}

      assert {:ok, mixed} = Editor.mixdown(placements)
      # Wrapping would turn +120000 into a large NEGATIVE sample: a full-scale
      # sign flip, the loudest artifact possible.
      assert samples(mixed) == [32_767, -32_768]
    end

    test "a negative offset is treated as the start of the ruler" do
      one = clip([7, 7])
      assert {:ok, mixed} = Editor.mixdown([{one, -5_000}])
      assert samples(mixed) == [7, 7]
    end

    test "refuses an empty arrangement and a format mismatch" do
      assert {:error, :empty_selection} = Editor.mixdown([])

      wide = %{clip([1, 2]) | sample_rate: 44_100}
      assert {:error, :format_mismatch} = Editor.mixdown([{clip([1, 2]), 0}, {wide, 0}])
    end

    test "refuses a render longer than the ceiling rather than eating the machine" do
      # A clip dragged to the far end of a ruler should report, not allocate
      # minutes of integer lists.
      assert {:error, :too_long} = Editor.mixdown([{clip([1]), 400_000}])
    end

    test "a mixdown is a normal clip — renderable, measurable, saveable" do
      assert {:ok, mixed} = Editor.mixdown([{clip(List.duplicate(1_000, 100)), 50}])
      assert Editor.internal?(mixed)
      assert {:ok, ^mixed} = Editor.parse(Editor.render(mixed))
    end
  end

  describe "concat/1" do
    test "refuses clips whose formats disagree" do
      a = clip([1, 2])
      b = %{clip([3, 4]) | sample_rate: 44_100}

      assert {:error, :format_mismatch} = Editor.concat([a, b])
      assert {:error, :empty_selection} = Editor.concat([])
    end
  end

  describe "measurement" do
    test "duration follows the sample count and rate" do
      assert_in_delta Editor.duration_ms(clip(List.duplicate(0, 22_050))), 1_000.0, 0.001
    end

    test "peak reads full scale as 1.0 and silence as 0.0" do
      assert_in_delta Editor.peak(clip([32_767, -100])), 1.0, 0.0001
      assert Editor.peak(clip([0, 0])) == 0.0
    end
  end

  describe "the workspace folder" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_studiodir_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)

      on_exit(fn ->
        Application.put_env(:buster_claw, :workspace_root, prev)
        File.rm_rf(root)
      end)

      {:ok, root: root}
    end

    test "is `studio/`, NOT `sounds/` — an import must not become a chime by basename" do
      assert Path.basename(Editor.dir()) == "studio"
      # `sounds/` is the effects library, where a file overrides a bundled chime
      # by basename. A three-minute voicemail landing there would silently
      # enlist itself as `voicemail.wav`.
      refute Editor.dir() == BusterClaw.Notifications.Sound.dir()
    end

    test "ensure/0 creates the folder and a README so it is visible in the workspace" do
      assert :ok = Editor.ensure()
      assert File.dir?(Editor.dir())
      assert File.exists?(Path.join(Editor.dir(), "README.md"))
    end

    test "ensure/0 does not overwrite a README the operator edited" do
      Editor.ensure()
      readme = Path.join(Editor.dir(), "README.md")
      File.write!(readme, "mine")

      Editor.ensure()
      assert File.read!(readme) == "mine"
    end

    if @decoder_available do
      test "store/2 gates by DECODING, not by extension" do
        Editor.ensure()
        prose = Path.join(System.tmp_dir!(), "prose-#{System.unique_integer([:positive])}.wav")
        File.write!(prose, "I am prose wearing a .wav extension")
        on_exit(fn -> File.rm(prose) end)

        # Passes the extension check, fails the decode — so it never lands and
        # never becomes a sidebar entry that breaks on selection.
        assert {:error, :not_audio} = Editor.store(prose, "prose.wav")
        assert Editor.list() == []
      end

      test "store/2 refuses a format the studio cannot take at all" do
        source = Path.join(System.tmp_dir!(), "doc-#{System.unique_integer([:positive])}.pdf")
        File.write!(source, SoundGen.render("boot"))
        on_exit(fn -> File.rm(source) end)

        assert {:error, :unsupported_format} = Editor.store(source, "doc.pdf")
      end

      test "store/2 lands a real file, and two of the same name coexist" do
        source = Path.join(System.tmp_dir!(), "clip-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)

        assert {:ok, "clip.wav"} = Editor.store(source, "clip.wav")
        assert {:ok, "clip-2.wav"} = Editor.store(source, "clip.wav")
        assert Editor.list() == ["clip-2.wav", "clip.wav"]
      end

      test "store/2 reduces a hostile name to a safe basename" do
        source = Path.join(System.tmp_dir!(), "eve-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)

        assert {:ok, stored} = Editor.store(source, "../../etc/evil.wav")
        refute stored =~ "/"
        refute stored =~ ".."
        assert File.regular?(Path.join(Editor.dir(), stored))
      end

      test "path_for/1 is an allowlist over the real listing, so traversal never resolves" do
        source = Path.join(System.tmp_dir!(), "ok-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)
        {:ok, name} = Editor.store(source, "ok.wav")

        assert Editor.path_for(name)
        assert is_nil(Editor.path_for("../../etc/passwd"))
        assert is_nil(Editor.path_for("nope.wav"))
        assert is_nil(Editor.path_for(nil))
      end

      test "delete/1 removes a stored file and refuses anything else" do
        source = Path.join(System.tmp_dir!(), "gone-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)
        {:ok, name} = Editor.store(source, "gone.wav")

        assert :ok = Editor.delete(name)
        assert Editor.list() == []
        assert {:error, :not_found} = Editor.delete(name)
      end
    end
  end

  describe "import_source/1" do
    test "a file that is already internal format is taken without the decoder" do
      path =
        Path.join(System.tmp_dir!(), "studio-internal-#{System.unique_integer([:positive])}.wav")

      File.write!(path, SoundGen.render("confirm"))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, clip} = Editor.import_source(path)
      assert Editor.internal?(clip)
      assert Editor.render(clip) == SoundGen.render("confirm")
    end

    test "a missing file reports rather than raises" do
      assert {:error, :not_found} = Editor.import_source("/no/such/file.wav")
      assert {:error, :not_found} = Editor.import_source(nil)
    end

    if @decoder_available do
      test "a 44.1 kHz stereo source is downmixed and resampled to the internal format" do
        # Built by hand, so this needs no encoder: 44.1 kHz, two channels.
        frames = for i <- 0..4409, do: rem(i * 7, 20_000) - 10_000
        data = for s <- frames, into: <<>>, do: <<s::little-signed-16, s::little-signed-16>>

        wide = %Editor{sample_rate: 44_100, channels: 2, bits: 16, data: data}

        path =
          Path.join(System.tmp_dir!(), "studio-wide-#{System.unique_integer([:positive])}.wav")

        File.write!(path, Editor.render(wide))
        on_exit(fn -> File.rm(path) end)

        assert {:ok, clip} = Editor.import_source(path)
        assert Editor.internal?(clip)
        # ~100 ms in, ~100 ms out (allow the resampler a few samples of slack).
        assert_in_delta Editor.duration_ms(clip), 100.0, 5.0
      end

      test "a compressed source decodes to the internal format" do
        source =
          Path.join(System.tmp_dir!(), "studio-src-#{System.unique_integer([:positive])}.wav")

        m4a = Path.join(System.tmp_dir!(), "studio-src-#{System.unique_integer([:positive])}.m4a")
        File.write!(source, SoundGen.render("alarm"))

        on_exit(fn ->
          File.rm(source)
          File.rm(m4a)
        end)

        {_out, 0} = System.cmd("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", source, m4a])

        assert {:ok, clip} = Editor.import_source(m4a)
        assert Editor.internal?(clip)
        assert Editor.duration_ms(clip) > 0
      end

      test "a text file fails cleanly instead of producing noise" do
        path =
          Path.join(System.tmp_dir!(), "studio-text-#{System.unique_integer([:positive])}.wav")

        File.write!(path, "I am prose wearing a .wav extension")
        on_exit(fn -> File.rm(path) end)

        assert {:error, :unsupported_source} = Editor.import_source(path)
      end
    end
  end

  describe "probe/1" do
    # Needs /usr/bin/afinfo, which exists only on macOS; off Darwin `probe/1`
    # correctly answers {:error, :no_prober} and there is nothing to assert.
    @tag :macos
    test "reads duration and format from the header without decoding" do
      path =
        Path.join(System.tmp_dir!(), "studio-probe-#{System.unique_integer([:positive])}.wav")

      File.write!(path, SoundGen.render("confirm"))
      on_exit(fn -> File.rm(path) end)

      {:ok, clip} = Editor.import_source(path)

      assert {:ok, probed} = Editor.probe(path)
      # afinfo's header estimate must agree with the decoded truth.
      assert_in_delta probed.duration_ms, Editor.duration_ms(clip), 5.0
      assert probed.sample_rate == clip.sample_rate
      assert probed.channels == clip.channels
    end

    test "a missing file reports rather than raises" do
      assert {:error, :not_found} = Editor.probe("/no/such/file.wav")
      assert {:error, :not_found} = Editor.probe(nil)
    end

    @tag :macos
    test "a text file fails cleanly" do
      path =
        Path.join(
          System.tmp_dir!(),
          "studio-probe-text-#{System.unique_integer([:positive])}.wav"
        )

      File.write!(path, "I am prose wearing a .wav extension")
      on_exit(fn -> File.rm(path) end)

      assert {:error, :unsupported_source} = Editor.probe(path)
    end
  end
end
