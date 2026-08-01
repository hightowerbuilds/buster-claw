defmodule BusterClaw.Notifications.SoundStudioTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Notifications.SoundStudio

  # afconvert is a macOS system binary, but the suite should not fail on a
  # machine that lacks it — the decode tests define themselves out instead.
  @decoder_available File.regular?("/usr/bin/afconvert")

  # A clip from a list of int16 samples, at the internal format.
  defp clip(samples) do
    %SoundStudio{data: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)}
  end

  defp samples(%SoundStudio{data: data}), do: for(<<s::little-signed-16 <- data>>, do: s)

  describe "parse/1 and render/1" do
    test "every bundled chime survives a parse/render round trip byte-identically" do
      for key <- SoundGen.keys() do
        original = SoundGen.render(key)
        assert {:ok, parsed} = SoundStudio.parse(original)

        assert SoundStudio.render(parsed) == original,
               "#{key}: round trip changed the bytes"
      end
    end

    test "a parsed chime reports the internal format" do
      assert {:ok, parsed} = SoundStudio.parse(SoundGen.render("boot"))
      assert SoundStudio.internal?(parsed)
      assert {22_050, 1, 16} == SoundStudio.internal_format()
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

      assert {:ok, parsed} = SoundStudio.parse(binary)
      assert samples(parsed) == [1, -1, 2, -2]
    end

    test "refuses things that are not WAVs, and lying chunk lengths" do
      assert {:error, :not_a_wav} = SoundStudio.parse("this is a text file, not audio")
      assert {:error, :not_a_wav} = SoundStudio.parse(<<>>)

      truncated =
        <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
          22_050::little-32, 44_100::little-32, 2::little-16, 16::little-16>> <>
          <<"data", 9_999::little-32, 0, 0>>

      assert {:error, :malformed_wav} = SoundStudio.parse(truncated)
    end
  end

  describe "splice/3 — the boundary arithmetic" do
    # 1000 samples at 22050 Hz. Sample N holds value N, so a splice's exact
    # first and last sample are readable off the result.
    setup do: %{ramp: clip(Enum.to_list(0..999))}

    test "is half-open: `from` is included, `to` is excluded", %{ramp: ramp} do
      # 0..99 inclusive == 100 samples, at 22050 Hz that is 0 to ~4.535 ms.
      to_ms = 100 * 1000 / 22_050
      assert {:ok, cut} = SoundStudio.splice(ramp, 0, to_ms)

      got = samples(cut)
      assert length(got) == 100
      assert List.first(got) == 0
      assert List.last(got) == 99, "the `to` sample leaked into the selection"
    end

    test "adjacent cuts tile exactly — no repeated sample at the seam", %{ramp: ramp} do
      mid = 500 * 1000 / 22_050
      total = 1000 * 1000 / 22_050

      assert {:ok, a} = SoundStudio.splice(ramp, 0, mid)
      assert {:ok, b} = SoundStudio.splice(ramp, mid, total)
      assert {:ok, joined} = SoundStudio.concat([a, b])

      # If the end were inclusive, sample 500 would appear twice and this would
      # be 1001 samples with an audible step at the join.
      assert samples(joined) == samples(ramp)
    end

    test "clamps out-of-range selections instead of raising", %{ramp: ramp} do
      assert {:ok, cut} = SoundStudio.splice(ramp, -500, 999_999)
      assert samples(cut) == samples(ramp)
    end

    test "refuses an empty or inverted selection", %{ramp: ramp} do
      assert {:error, :empty_selection} = SoundStudio.splice(ramp, 5, 5)
      assert {:error, :empty_selection} = SoundStudio.splice(ramp, 8, 2)
    end
  end

  describe "fade/2" do
    test "lands on true zero at both edges" do
      flat = clip(List.duplicate(10_000, 500))
      ms = 100 * 1000 / 22_050

      faded = SoundStudio.fade(flat, in_ms: ms, out_ms: ms)
      got = samples(faded)

      assert List.first(got) == 0, "fade-in did not start from silence"
      assert List.last(got) == 0, "fade-out did not reach silence"
      # The untouched middle keeps full amplitude.
      assert Enum.at(got, 250) == 10_000
    end

    test "is monotonic across the ramp — no bumps on the way up" do
      flat = clip(List.duplicate(10_000, 500))
      ms = 100 * 1000 / 22_050
      ramp = faded_head(SoundStudio.fade(flat, in_ms: ms), 100)

      assert ramp == Enum.sort(ramp)
      assert List.last(ramp) <= 10_000
    end

    test "ramps longer than the clip are clamped, not an error" do
      flat = clip(List.duplicate(10_000, 100))
      faded = SoundStudio.fade(flat, in_ms: 10_000, out_ms: 10_000)

      assert length(samples(faded)) == 100
      assert Enum.all?(samples(faded), &(abs(&1) <= 10_000))
    end

    test "a zero-length or single-sample ramp is a no-op, not a silencer" do
      flat = clip(List.duplicate(10_000, 50))
      assert samples(SoundStudio.fade(flat, in_ms: 0, out_ms: 0)) == samples(flat)
    end

    defp faded_head(clip, n), do: clip |> samples() |> Enum.take(n)
  end

  describe "normalize/2" do
    test "brings a quiet clip up to the target" do
      quiet = clip([1_000, -1_000, 500])
      normalized = SoundStudio.normalize(quiet)

      assert_in_delta SoundStudio.peak(normalized), 0.891, 0.001
    end

    test "never clips — not even from int16's extra-loud negative rail" do
      # -32768 has no positive counterpart; scaling it naively overflows to a
      # full-scale sign flip, the loudest artifact a sample can produce.
      hot = clip([-32_768, 32_767, -32_768])

      for target <- [0.5, 0.891, 1.0] do
        got = samples(SoundStudio.normalize(hot, target))
        assert Enum.all?(got, &(&1 >= -32_768 and &1 <= 32_767))
      end
    end

    test "silence is returned untouched rather than divided by zero" do
      silence = clip(List.duplicate(0, 64))
      assert samples(SoundStudio.normalize(silence)) == samples(silence)
    end

    test "an empty clip does not crash the gain calculation" do
      assert samples(SoundStudio.normalize(clip([]))) == []
    end
  end

  describe "concat/1" do
    test "refuses clips whose formats disagree" do
      a = clip([1, 2])
      b = %{clip([3, 4]) | sample_rate: 44_100}

      assert {:error, :format_mismatch} = SoundStudio.concat([a, b])
      assert {:error, :empty_selection} = SoundStudio.concat([])
    end
  end

  describe "measurement" do
    test "duration follows the sample count and rate" do
      assert_in_delta SoundStudio.duration_ms(clip(List.duplicate(0, 22_050))), 1_000.0, 0.001
    end

    test "peak reads full scale as 1.0 and silence as 0.0" do
      assert_in_delta SoundStudio.peak(clip([32_767, -100])), 1.0, 0.0001
      assert SoundStudio.peak(clip([0, 0])) == 0.0
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
      assert Path.basename(SoundStudio.dir()) == "studio"
      # `sounds/` is the effects library, where a file overrides a bundled chime
      # by basename. A three-minute voicemail landing there would silently
      # enlist itself as `voicemail.wav`.
      refute SoundStudio.dir() == BusterClaw.Notifications.Sound.dir()
    end

    test "ensure/0 creates the folder and a README so it is visible in the workspace" do
      assert :ok = SoundStudio.ensure()
      assert File.dir?(SoundStudio.dir())
      assert File.exists?(Path.join(SoundStudio.dir(), "README.md"))
    end

    test "ensure/0 does not overwrite a README the operator edited" do
      SoundStudio.ensure()
      readme = Path.join(SoundStudio.dir(), "README.md")
      File.write!(readme, "mine")

      SoundStudio.ensure()
      assert File.read!(readme) == "mine"
    end

    if @decoder_available do
      test "store/2 gates by DECODING, not by extension" do
        SoundStudio.ensure()
        prose = Path.join(System.tmp_dir!(), "prose-#{System.unique_integer([:positive])}.wav")
        File.write!(prose, "I am prose wearing a .wav extension")
        on_exit(fn -> File.rm(prose) end)

        # Passes the extension check, fails the decode — so it never lands and
        # never becomes a sidebar entry that breaks on selection.
        assert {:error, :not_audio} = SoundStudio.store(prose, "prose.wav")
        assert SoundStudio.list() == []
      end

      test "store/2 refuses a format the studio cannot take at all" do
        source = Path.join(System.tmp_dir!(), "doc-#{System.unique_integer([:positive])}.pdf")
        File.write!(source, SoundGen.render("boot"))
        on_exit(fn -> File.rm(source) end)

        assert {:error, :unsupported_format} = SoundStudio.store(source, "doc.pdf")
      end

      test "store/2 lands a real file, and two of the same name coexist" do
        source = Path.join(System.tmp_dir!(), "clip-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)

        assert {:ok, "clip.wav"} = SoundStudio.store(source, "clip.wav")
        assert {:ok, "clip-2.wav"} = SoundStudio.store(source, "clip.wav")
        assert SoundStudio.list() == ["clip-2.wav", "clip.wav"]
      end

      test "store/2 reduces a hostile name to a safe basename" do
        source = Path.join(System.tmp_dir!(), "eve-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)

        assert {:ok, stored} = SoundStudio.store(source, "../../etc/evil.wav")
        refute stored =~ "/"
        refute stored =~ ".."
        assert File.regular?(Path.join(SoundStudio.dir(), stored))
      end

      test "path_for/1 is an allowlist over the real listing, so traversal never resolves" do
        source = Path.join(System.tmp_dir!(), "ok-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)
        {:ok, name} = SoundStudio.store(source, "ok.wav")

        assert SoundStudio.path_for(name)
        assert is_nil(SoundStudio.path_for("../../etc/passwd"))
        assert is_nil(SoundStudio.path_for("nope.wav"))
        assert is_nil(SoundStudio.path_for(nil))
      end

      test "delete/1 removes a stored file and refuses anything else" do
        source = Path.join(System.tmp_dir!(), "gone-#{System.unique_integer([:positive])}.wav")
        File.write!(source, SoundGen.render("chat"))
        on_exit(fn -> File.rm(source) end)
        {:ok, name} = SoundStudio.store(source, "gone.wav")

        assert :ok = SoundStudio.delete(name)
        assert SoundStudio.list() == []
        assert {:error, :not_found} = SoundStudio.delete(name)
      end
    end
  end

  describe "import_source/1" do
    test "a file that is already internal format is taken without the decoder" do
      path =
        Path.join(System.tmp_dir!(), "studio-internal-#{System.unique_integer([:positive])}.wav")

      File.write!(path, SoundGen.render("confirm"))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, clip} = SoundStudio.import_source(path)
      assert SoundStudio.internal?(clip)
      assert SoundStudio.render(clip) == SoundGen.render("confirm")
    end

    test "a missing file reports rather than raises" do
      assert {:error, :not_found} = SoundStudio.import_source("/no/such/file.wav")
      assert {:error, :not_found} = SoundStudio.import_source(nil)
    end

    if @decoder_available do
      test "a 44.1 kHz stereo source is downmixed and resampled to the internal format" do
        # Built by hand, so this needs no encoder: 44.1 kHz, two channels.
        frames = for i <- 0..4409, do: rem(i * 7, 20_000) - 10_000
        data = for s <- frames, into: <<>>, do: <<s::little-signed-16, s::little-signed-16>>

        wide = %SoundStudio{sample_rate: 44_100, channels: 2, bits: 16, data: data}

        path =
          Path.join(System.tmp_dir!(), "studio-wide-#{System.unique_integer([:positive])}.wav")

        File.write!(path, SoundStudio.render(wide))
        on_exit(fn -> File.rm(path) end)

        assert {:ok, clip} = SoundStudio.import_source(path)
        assert SoundStudio.internal?(clip)
        # ~100 ms in, ~100 ms out (allow the resampler a few samples of slack).
        assert_in_delta SoundStudio.duration_ms(clip), 100.0, 5.0
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

        assert {:ok, clip} = SoundStudio.import_source(m4a)
        assert SoundStudio.internal?(clip)
        assert SoundStudio.duration_ms(clip) > 0
      end

      test "a text file fails cleanly instead of producing noise" do
        path =
          Path.join(System.tmp_dir!(), "studio-text-#{System.unique_integer([:positive])}.wav")

        File.write!(path, "I am prose wearing a .wav extension")
        on_exit(fn -> File.rm(path) end)

        assert {:error, :unsupported_source} = SoundStudio.import_source(path)
      end
    end
  end
end
