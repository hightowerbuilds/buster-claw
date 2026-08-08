defmodule BusterClaw.Notifications.Cutup.AssembleTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Cutup.Assemble
  alias BusterClaw.Notifications.SoundStudio

  @rate 22_050

  # afconvert is a macOS system binary, but the suite should not fail on a
  # machine that lacks it — the cross-format test defines itself out instead.
  # (The same posture as `sound_studio_test.exs`.)
  @decoder_available File.regular?("/usr/bin/afconvert")

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cutup_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    File.mkdir_p!(SoundStudio.dir())

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  #
  # Sources are constant-amplitude on purpose: with a distinct amplitude per
  # file, every sample in the assembled clip says which source it came from, so
  # order and seam position are assertable without a correlator.
  # ---------------------------------------------------------------------------

  # Sample index for a millisecond offset, using SoundStudio's own rounding.
  # Every expected length below is expressed with this, so the tests pin the
  # arithmetic rather than re-deriving it with a different rounding rule.
  defp at(ms), do: round(ms * @rate / 1000)

  defp source(name, ms, amplitude) do
    data = :binary.copy(<<amplitude::little-signed-16>>, at(ms))
    write(name, %SoundStudio{data: data})
  end

  defp write(name, %SoundStudio{} = clip) do
    :ok = SoundStudio.write(clip, Path.join(SoundStudio.dir(), name))
    name
  end

  defp samples(%SoundStudio{data: data}), do: for(<<s::little-signed-16 <- data>>, do: s)

  defp cut(source, from, to), do: %{source: source, start_ms: from, end_ms: to}

  # Shaping off, so length and amplitude assertions read the splice arithmetic
  # and nothing else. Individual tests turn the pieces they are about back on.
  defp plain(opts \\ []) do
    Keyword.merge([pad_ms: 0, fade_ms: 0, gap_ms: 0, normalize: false], opts)
  end

  describe "the arithmetic" do
    test "the assembled length is the sum of the padded spans plus the gaps" do
      source("a.wav", 2000.0, 8000)

      cuts = [
        cut("a.wav", 100.0, 300.0),
        cut("a.wav", 700.0, 760.0),
        cut("a.wav", 1500.0, 1900.0)
      ]

      assert {:ok, clip} =
               Assemble.build(cuts, pad_ms: 30, fade_ms: 8, gap_ms: 60, normalize: false)

      spans =
        at(330) - at(70) +
          (at(790) - at(670)) +
          (at(1930) - at(1470))

      gaps = 2 * at(60)

      assert_in_delta SoundStudio.sample_count(clip), spans + gaps, 2
      assert_in_delta SoundStudio.duration_ms(clip), (spans + gaps) * 1000 / @rate, 0.1
    end

    test "the result is one clip in the internal format" do
      source("a.wav", 500.0, 8000)

      assert {:ok, clip} = Assemble.build([cut("a.wav", 100.0, 200.0)])
      assert SoundStudio.internal?(clip)
      assert {clip.sample_rate, clip.channels, clip.bits} == SoundStudio.internal_format()
    end

    test "the defaults are the documented ones" do
      source("a.wav", 500.0, 8000)
      cuts = [cut("a.wav", 100.0, 200.0), cut("a.wav", 300.0, 400.0)]

      assert {:ok, default} = Assemble.build(cuts)

      assert {:ok, explicit} =
               Assemble.build(cuts, pad_ms: 30, fade_ms: 8, gap_ms: 60, normalize: true)

      assert default == explicit
    end
  end

  describe "order" do
    test "three cuts from three sources come out in the order requested" do
      source("one.wav", 500.0, 3000)
      source("two.wav", 500.0, -6000)
      source("three.wav", 500.0, 9000)

      cuts = [
        cut("two.wav", 100.0, 200.0),
        cut("three.wav", 100.0, 200.0),
        cut("one.wav", 100.0, 200.0)
      ]

      assert {:ok, clip} = Assemble.build(cuts, plain())

      n = at(200) - at(100)
      got = samples(clip)

      assert length(got) == 3 * n
      assert Enum.at(got, div(n, 2)) == -6000
      assert Enum.at(got, n + div(n, 2)) == 9000
      assert Enum.at(got, 2 * n + div(n, 2)) == 3000
    end

    test "the same source used many times still assembles in order" do
      source("a.wav", 1000.0, 7000)

      cuts =
        for start <- [0.0, 100.0, 200.0, 300.0, 400.0, 500.0],
            do: cut("a.wav", start, start + 50.0)

      assert {:ok, clip} = Assemble.build(cuts, plain())
      assert SoundStudio.sample_count(clip) == 6 * (at(50) - at(0))
    end
  end

  describe "padding" do
    test "padding widens the cut on both sides" do
      source("a.wav", 1000.0, 8000)
      cuts = [cut("a.wav", 100.0, 300.0)]

      assert {:ok, tight} = Assemble.build(cuts, plain(pad_ms: 0))
      assert {:ok, padded} = Assemble.build(cuts, plain(pad_ms: 50))

      assert SoundStudio.sample_count(padded) > SoundStudio.sample_count(tight)

      widened = SoundStudio.sample_count(padded) - SoundStudio.sample_count(tight)
      assert_in_delta widened, 2 * at(50), 2
    end

    test "padding clamps at the start of the clip rather than erroring" do
      source("a.wav", 200.0, 5000)

      # A word at 0 ms — somebody talking over the beep — is ordinary, not an
      # error, and it must still come out padded on the side that has room.
      assert {:ok, clip} = Assemble.build([cut("a.wav", 0.0, 100.0)], plain(pad_ms: 50))
      assert SoundStudio.sample_count(clip) == at(150) - at(0)
    end

    test "padding clamps at the end of the clip rather than erroring" do
      source("a.wav", 200.0, 5000)

      assert {:ok, clip} = Assemble.build([cut("a.wav", 100.0, 200.0)], plain(pad_ms: 50))
      assert SoundStudio.sample_count(clip) == at(200) - at(50)
    end

    test "a cut spanning the whole clip clamps on both sides at once" do
      source("a.wav", 200.0, 5000)

      assert {:ok, clip} = Assemble.build([cut("a.wav", 0.0, 200.0)], plain(pad_ms: 100))
      assert SoundStudio.sample_count(clip) == at(200)
    end

    test "a negative pad is floored to zero instead of narrowing the cut" do
      source("a.wav", 500.0, 5000)
      cuts = [cut("a.wav", 100.0, 200.0)]

      assert {:ok, floored} = Assemble.build(cuts, plain(pad_ms: -50))
      assert {:ok, none} = Assemble.build(cuts, plain(pad_ms: 0))
      assert SoundStudio.sample_count(floored) == SoundStudio.sample_count(none)
    end
  end

  describe "fades" do
    for normalize <- [true, false] do
      test "the fade lands on true zero at every seam (normalize: #{normalize})" do
        source("a.wav", 500.0, 12_000)
        source("b.wav", 500.0, -12_000)

        cuts = [cut("a.wav", 100.0, 200.0), cut("b.wav", 100.0, 200.0)]

        assert {:ok, clip} =
                 Assemble.build(cuts,
                   pad_ms: 0,
                   fade_ms: 8,
                   gap_ms: 0,
                   normalize: unquote(normalize)
                 )

        n = at(200) - at(100)
        got = samples(clip)
        assert length(got) == 2 * n

        # Both ends of both contributed regions, which is every seam there is:
        # the head, the join, and the tail.
        assert Enum.at(got, 0) == 0
        assert Enum.at(got, n - 1) == 0
        assert Enum.at(got, n) == 0
        assert Enum.at(got, 2 * n - 1) == 0

        # …and the fade shaped the edges only. The word is still there.
        assert Enum.at(got, div(n, 2)) != 0
        assert Enum.at(got, n + div(n, 2)) != 0
      end
    end

    test "without a fade the seam is a step, which is what the fade is for" do
      source("a.wav", 500.0, 12_000)

      assert {:ok, clip} = Assemble.build([cut("a.wav", 100.0, 200.0)], plain())
      got = samples(clip)

      assert List.first(got) == 12_000
      assert List.last(got) == 12_000
    end

    test "normalize levels two sources that arrived at different levels" do
      source("loud.wav", 500.0, 20_000)
      source("quiet.wav", 500.0, 500)

      cuts = [cut("loud.wav", 100.0, 200.0), cut("quiet.wav", 100.0, 200.0)]

      assert {:ok, levelled} = Assemble.build(cuts, plain(normalize: true))
      n = at(200) - at(100)
      got = samples(levelled)

      # Peaks equalized, not loudness — but 40x apart becomes within a hair.
      assert_in_delta Enum.at(got, div(n, 2)), abs(Enum.at(got, n + div(n, 2))), 2

      assert {:ok, raw} = Assemble.build(cuts, plain(normalize: false))
      raw_got = samples(raw)
      assert Enum.at(raw_got, div(n, 2)) == 20_000
      assert Enum.at(raw_got, n + div(n, 2)) == 500
    end
  end

  describe "gaps" do
    test "gap_ms: 0 puts nothing between the cuts" do
      source("a.wav", 500.0, 7000)
      source("b.wav", 500.0, -7000)

      cuts = [cut("a.wav", 100.0, 200.0), cut("b.wav", 100.0, 200.0)]
      assert {:ok, clip} = Assemble.build(cuts, plain(gap_ms: 0))

      n = at(200) - at(100)
      got = samples(clip)

      assert length(got) == 2 * n
      # The two regions abut: the last sample of the first is immediately
      # followed by the first sample of the second, with no silence at all.
      assert Enum.at(got, n - 1) == 7000
      assert Enum.at(got, n) == -7000
    end

    test "a positive gap yields exactly that much silence, in the right place" do
      source("a.wav", 500.0, 7000)
      source("b.wav", 500.0, -7000)

      cuts = [cut("a.wav", 100.0, 200.0), cut("b.wav", 100.0, 200.0)]
      assert {:ok, clip} = Assemble.build(cuts, plain(gap_ms: 100))

      n = at(200) - at(100)
      gap = at(100)
      got = samples(clip)

      assert length(got) == 2 * n + gap
      assert Enum.at(got, n - 1) == 7000
      assert Enum.all?(Enum.slice(got, n, gap), &(&1 == 0))
      assert Enum.at(got, n + gap) == -7000
    end

    test "a single cut gets no gap at all — silence goes between, not around" do
      source("a.wav", 500.0, 7000)

      assert {:ok, clip} = Assemble.build([cut("a.wav", 100.0, 200.0)], plain(gap_ms: 500))
      assert SoundStudio.sample_count(clip) == at(200) - at(100)
    end

    test "n cuts get n-1 gaps" do
      source("a.wav", 1000.0, 7000)
      cuts = for start <- [0.0, 200.0, 400.0, 600.0], do: cut("a.wav", start, start + 100.0)

      assert {:ok, clip} = Assemble.build(cuts, plain(gap_ms: 100))
      span = at(100) - at(0)
      assert SoundStudio.sample_count(clip) == 4 * span + 3 * at(100)
    end
  end

  describe "errors are named, never raised" do
    test "an empty selection" do
      assert {:error, :empty_selection} = Assemble.build([])
      assert {:error, :empty_selection} = Assemble.build([], pad_ms: 30)
      assert {:error, :empty_selection} = Assemble.build(nil)
    end

    test "a source that does not exist names the source" do
      source("a.wav", 500.0, 7000)

      cuts = [cut("a.wav", 100.0, 200.0), cut("ghost.wav", 100.0, 200.0)]
      assert {:error, {:source_not_found, "ghost.wav"}} = Assemble.build(cuts)
    end

    test "a path-shaped source is refused as a name, not resolved" do
      assert {:error, {:source_not_found, "../../etc/passwd"}} =
               Assemble.build([cut("../../etc/passwd", 0.0, 100.0)])

      assert {:error, {:source_not_found, "/etc/passwd"}} =
               Assemble.build([cut("/etc/passwd", 0.0, 100.0)])
    end

    test "an inverted span names the offending cut, not `:empty_selection`" do
      source("a.wav", 500.0, 7000)
      bad = cut("a.wav", 300.0, 100.0)

      # The point of the named error: in a forty-word sentence, a bare
      # `:empty_selection` from splice/3 would read as "you selected nothing".
      assert {:error, {:invalid_span, ^bad}} =
               Assemble.build([cut("a.wav", 0.0, 50.0), bad, cut("a.wav", 100.0, 150.0)])
    end

    test "a zero-length span names the offending cut" do
      source("a.wav", 500.0, 7000)
      bad = cut("a.wav", 100.0, 100.0)

      assert {:error, {:invalid_span, ^bad}} = Assemble.build([bad])
    end

    test "a span wholly past the end of the clip is named separately" do
      source("a.wav", 200.0, 7000)
      bad = cut("a.wav", 5000.0, 5100.0)

      # Well-formed times, wrong file (or a stale index) — a different fix from
      # an inverted span, so a different name.
      assert {:error, {:span_outside_clip, ^bad}} = Assemble.build([bad])
    end

    test "a malformed cut is named as a cut problem, not a span problem" do
      sourceless = %{start_ms: 0.0, end_ms: 100.0}
      assert Assemble.build([sourceless]) == {:error, {:invalid_cut, sourceless}}

      assert {:error, {:invalid_cut, _}} =
               Assemble.build([%{source: "a.wav", start_ms: "0", end_ms: 100.0}])

      assert {:error, {:invalid_cut, _}} = Assemble.build([:not_a_cut])
    end

    test "a file that is not audio names the source and the reason" do
      File.write!(Path.join(SoundStudio.dir(), "junk.wav"), "this is prose, not a waveform")

      assert {:error, {:unreadable_source, "junk.wav", _reason}} =
               Assemble.build([cut("junk.wav", 0.0, 100.0)])
    end

    test "the first bad cut stops the build — a sentence is not partially right" do
      source("a.wav", 500.0, 7000)

      cuts = [cut("a.wav", 0.0, 100.0), cut("ghost.wav", 0.0, 100.0), cut("nope.wav", 0.0, 100.0)]
      assert {:error, {:source_not_found, "ghost.wav"}} = Assemble.build(cuts)
    end
  end

  if @decoder_available do
    describe "mixed formats" do
      test "a source in another format is normalized on the way in and joins cleanly" do
        source("internal.wav", 500.0, 6000)

        # 44.1 kHz stereo — the shape a carrier or a phone recording arrives in.
        frame = <<4000::little-signed-16, 4000::little-signed-16>>

        write("wide.wav", %SoundStudio{
          sample_rate: 44_100,
          channels: 2,
          bits: 16,
          data: :binary.copy(frame, div(44_100 * 400, 1000))
        })

        cuts = [cut("wide.wav", 100.0, 300.0), cut("internal.wav", 100.0, 300.0)]
        assert {:ok, clip} = Assemble.build(cuts, plain(pad_ms: 30))

        # Everything past `import_source/1` is one format, so this is a join and
        # not a conversion — and `concat/1` would have said `:format_mismatch`
        # if it were not.
        assert SoundStudio.internal?(clip)

        # Two 260 ms spans, one of which was resampled: allow the resampler a
        # few samples of slop, but not a factor of two.
        assert_in_delta SoundStudio.duration_ms(clip), 520.0, 15.0
      end
    end
  end
end
