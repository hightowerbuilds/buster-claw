defmodule BusterClaw.Notifications.Cutup.AlignTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Cutup.Align
  alias BusterClaw.Notifications.Cutup.Index

  doctest Align

  # These are float milliseconds all the way down, so every comparison that is
  # morally an equality gets a tolerance rather than `==`.
  @eps 1.0e-9

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp span(start_ms, end_ms) do
    %{
      start_ms: start_ms * 1.0,
      end_ms: end_ms * 1.0,
      frames: max(1, trunc((end_ms - start_ms) / 10))
    }
  end

  # Ten one-syllable words, so weighting is uniform and the arithmetic is
  # checkable by hand. None of them is a function word, so the default
  # multiplier is inert over this transcript.
  @ten "cat dog bird fish tree bee ant cow fox hen"

  # The analysis clock, restated from `Cutup.Vad` so a synthetic profile has the
  # same shape a real one does: frame `i` covers [i*10, i*10+25), so its CENTRE
  # — which is what `Align` snaps to — is at `i * 10 + 12.5`.
  @hop 10.0
  @frame 25.0

  defp centre_of(index), do: index * @hop + @frame / 2.0

  # A profile whose frames are exactly the RMS values given, in order. Every
  # other field is filled in the way `Vad.energy_profile/2` fills it, so a test
  # that starts passing against this one has a chance of passing against a real
  # one.
  defp profile(rms_values) do
    frames =
      rms_values
      |> Enum.with_index()
      |> Enum.map(fn {rms, i} ->
        %{
          index: i,
          start_ms: i * @hop,
          end_ms: i * @hop + @frame,
          rms: rms * 1.0,
          zcr: 0.05,
          enter?: rms >= 0.1,
          hold?: rms >= 0.05
        }
      end)

    %{
      frame_ms: @frame,
      hop_ms: @hop,
      frame_count: length(frames),
      duration_ms: length(frames) * @hop + @frame,
      thresholds: %{noise_floor: 0.001, enter: 0.1, leave: 0.05},
      frames: frames
    }
  end

  # `n` frames of steady speech-level energy, with a quiet trough dropped in at
  # each of `dips` — the shape of a real inter-word closure, exaggerated.
  defp profile(n, dips, quiet \\ 0.01, loud \\ 0.5) do
    0..(n - 1)
    |> Enum.map(fn i -> if i in dips, do: quiet, else: loud end)
    |> profile()
  end

  defp total_span_ms(spans), do: spans |> Enum.map(&(&1.end_ms - &1.start_ms)) |> Enum.sum()

  defp allotted_ms(words), do: words |> Enum.map(&(&1.end_ms - &1.start_ms)) |> Enum.sum()

  defp inside_a_span?(word, spans) do
    Enum.any?(spans, fn span ->
      word.start_ms >= span.start_ms - @eps and word.end_ms <= span.end_ms + @eps
    end)
  end

  # ---------------------------------------------------------------------------
  # The round numbers
  # ---------------------------------------------------------------------------

  describe "align/3 over one span" do
    test "ten equal-weight words over 1000 ms are ten contiguous 100 ms entries" do
      words = Align.align(@ten, [span(0, 1000)])

      assert length(words) == 10

      for {word, i} <- Enum.with_index(words) do
        assert_in_delta word.start_ms, i * 100.0, @eps
        assert_in_delta word.end_ms, (i + 1) * 100.0, @eps
      end
    end

    test "the entries tile the span with no gaps" do
      words = Align.align(@ten, [span(0, 1000)])

      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert_in_delta a.end_ms, b.start_ms, @eps end)
    end

    test "a span that does not start at zero is offset, not rescaled" do
      words = Align.align("cat dog", [span(4000, 4500)])

      assert [%{start_ms: 4000.0}, %{start_ms: 4250.0}] = words
      assert List.last(words).end_ms == 4500.0
    end

    test "word and text are the normalised and the raw forms" do
      [word] = Align.align("Harbor,", [span(0, 400)])

      assert word.word == "harbor"
      assert word.text == "Harbor,"
    end
  end

  # ---------------------------------------------------------------------------
  # The property that matters most: nothing lands in silence
  # ---------------------------------------------------------------------------

  describe "align/3 across many spans" do
    setup do
      spans = [span(0, 300), span(1000, 1500), span(2400, 2450), span(5000, 6200)]

      transcript =
        "I need you to call me back about the harbor thing tomorrow morning " <>
          "because the elephant paperwork is genuinely unbelievable now"

      %{spans: spans, transcript: transcript, words: Align.align(transcript, spans)}
    end

    test "every entry lies wholly inside some span", %{spans: spans, words: words} do
      assert length(words) > 10

      for word <- words do
        assert inside_a_span?(word, spans),
               "#{word.text} at #{word.start_ms}..#{word.end_ms} is not inside any span"
      end
    end

    test "entries are in time order and never overlap", %{words: words} do
      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert a.start_ms < b.start_ms
        assert a.end_ms <= b.start_ms + @eps
      end)
    end

    test "every entry has positive duration", %{words: words} do
      assert Enum.all?(words, &(&1.end_ms > &1.start_ms))
    end

    test "no time is invented: the total allotted never exceeds the total speech",
         %{spans: spans, words: words} do
      assert allotted_ms(words) <= total_span_ms(spans) + @eps
    end

    test "the output is accepted by Index.build/3 unchanged", %{words: words} do
      assert {:ok, index} = Index.build("voicemail-03.wav", words, origin: :imported)

      assert length(index.words) == length(words)
      assert index.origin == :imported
      assert Enum.map(index.words, & &1.word) == Enum.map(words, & &1.word)
    end
  end

  describe "conservation of time" do
    test "one span: the words account for exactly the span" do
      spans = [span(0, 1000)]
      assert_in_delta allotted_ms(Align.align(@ten, spans)), total_span_ms(spans), 1.0e-6
    end

    test "two spans with a boundary that falls between words: still exact" do
      # Ten equal words over 2 x 500 ms: the virtual boundary at 500 ms is
      # exactly where word 5 ends, so nothing straddles and nothing is lost.
      spans = [span(0, 500), span(9000, 9500)]
      words = Align.align(@ten, spans)

      assert length(words) == 10
      assert_in_delta allotted_ms(words), total_span_ms(spans), 1.0e-6
      assert Enum.map(words, & &1.start_ms) |> Enum.take(6) |> List.last() == 9000.0
    end
  end

  # ---------------------------------------------------------------------------
  # Weighting
  # ---------------------------------------------------------------------------

  describe "weighting" do
    # `a` is an article, so the function-word multiplier is on it by default;
    # this test is about the syllable arithmetic alone, so it names the
    # multiplier off rather than choosing a transcript that dodges it. The
    # assertions are unchanged — see "function words" below for the default.
    test "a polysyllabic word gets more time than a monosyllable in the same span" do
      [a, elephant] = Align.align("a elephant", [span(0, 400)], reduce_function_words: false)

      assert elephant.end_ms - elephant.start_ms > a.end_ms - a.start_ms
      # 1 syllable against 3.
      assert_in_delta a.end_ms - a.start_ms, 100.0, @eps
      assert_in_delta elephant.end_ms - elephant.start_ms, 300.0, @eps
    end

    test "syllable weighting is the default" do
      assert Align.align("a elephant", [span(0, 400)]) ==
               Align.align("a elephant", [span(0, 400)], weight: :syllables)
    end

    test "character weighting shares out by length instead" do
      opts = [weight: :characters, reduce_function_words: false]
      [a, elephant] = Align.align("a elephant", [span(0, 900)], opts)

      # 1 character against 8.
      assert_in_delta a.end_ms - a.start_ms, 100.0, @eps
      assert_in_delta elephant.end_ms - elephant.start_ms, 800.0, @eps
    end

    test "the two schemes disagree exactly where English orthography lies" do
      # `strengths` is nine letters and one beat; `idea` is four letters and
      # (really) three. The two schemes rank them in OPPOSITE orders, which is
      # the whole argument for preferring syllables.
      spans = [span(0, 1000)]

      [strengths, idea] = Align.align("strengths idea", spans)
      assert strengths.end_ms - strengths.start_ms < idea.end_ms - idea.start_ms

      [c_strengths, c_idea] = Align.align("strengths idea", spans, weight: :characters)
      assert c_strengths.end_ms - c_strengths.start_ms > c_idea.end_ms - c_idea.start_ms
    end

    test "an unrecognised weight option falls back to syllables rather than failing" do
      assert Align.align("a elephant", [span(0, 400)], weight: :phonemes) ==
               Align.align("a elephant", [span(0, 400)])
    end
  end

  describe "syllables/1" do
    test "counts vowel groups with the silent-e adjustment" do
      assert Align.syllables("cat") == 1
      assert Align.syllables("make") == 1
      assert Align.syllables("code") == 1
      assert Align.syllables("the") == 1
      assert Align.syllables("morning") == 2
      assert Align.syllables("harbor") == 2
      assert Align.syllables("elephant") == 3
      assert Align.syllables("unbelievable") == 5
    end

    test "a consonant-plus-le ending keeps its beat" do
      assert Align.syllables("table") == 2
      assert Align.syllables("apple") == 2
    end

    test "a leading y is a consonant, elsewhere it is a vowel" do
      assert Align.syllables("yes") == 1
      assert Align.syllables("yellow") == 2
      assert Align.syllables("my") == 1
    end

    test "punctuation and case do not change the count" do
      assert Align.syllables("Harbor,") == 2
      assert Align.syllables("o'clock") == 2
      assert Align.syllables("don't") == 1
    end

    test "digits each carry a beat" do
      assert Align.syllables("1997") == 4
    end

    test "never returns zero, whatever it is handed" do
      assert Align.syllables("") == 1
      assert Align.syllables("...") == 1
      assert Align.syllables("rhythm") == 1
      assert Align.syllables(nil) == 1
      assert Align.syllables(42) == 1
    end

    test "known misses, pinned so a future change is deliberate" do
      # Adjacent vowels in separate syllables read as one group.
      assert Align.syllables("idea") == 2
      assert Align.syllables("poem") == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Confidence
  # ---------------------------------------------------------------------------

  describe "confidence" do
    test "a plausible rate scores at the ceiling and never above it" do
      # Three syllables at the assumed 200 ms each.
      words = Align.align("cat dog bird", [span(0, 600)])

      for word <- words do
        assert_in_delta word.confidence, 0.9, 1.0e-9
      end
    end

    test "a plausible rate is still high when it is somewhat off" do
      # 150 ms a syllable: a brisk but ordinary speaker.
      words = Align.align("cat dog bird", [span(0, 450)])
      assert Enum.all?(words, &(&1.confidence > 0.65))
    end

    test "two words stretched over thirty seconds is not believable" do
      words = Align.align("hello world", [span(0, 30_000)])

      assert length(words) == 2
      assert Enum.all?(words, &(&1.confidence < 0.05))
    end

    test "two hundred words crammed into one second is not believable" do
      transcript = 1..200 |> Enum.map_join(" ", fn _ -> "cat" end)
      words = Align.align(transcript, [span(0, 1000)])

      assert length(words) == 200
      assert Enum.all?(words, &(&1.confidence < 0.05))
    end

    test "a hallucinated transcript is filtered out by Index's :min_confidence" do
      transcript = 1..200 |> Enum.map_join(" ", fn _ -> "cat" end)
      words = Align.align(transcript, [span(0, 1000)])

      assert {:ok, index} = Index.build("voicemail-03.wav", words, origin: :imported)
      assert Enum.all?(index.words, &(&1.confidence < 0.3))
    end

    test "the scale is documented and holds: half or double costs about a third" do
      [double] = Align.align("cat", [span(0, 400)])
      [half] = Align.align("cat", [span(0, 100)])

      assert_in_delta double.confidence, 0.9 * :math.exp(-0.5), 1.0e-6
      assert_in_delta half.confidence, 0.9 * :math.exp(-0.5), 1.0e-6
    end

    test "confidence is never a constant across differently-timed alignments" do
      good = Align.align("cat dog bird", [span(0, 600)])
      bad = Align.align("cat dog bird", [span(0, 6000)])

      assert hd(good).confidence > hd(bad).confidence * 10
    end

    test ":syllable_ms retunes the expectation for a fast speaker" do
      spans = [span(0, 300)]

      assert hd(Align.align("cat dog bird", spans)).confidence < 0.6

      assert_in_delta hd(Align.align("cat dog bird", spans, syllable_ms: 100)).confidence,
                      0.9,
                      1.0e-9
    end

    test "an unusable :syllable_ms falls back to the default" do
      spans = [span(0, 600)]

      assert Align.align("cat dog bird", spans, syllable_ms: 0) ==
               Align.align("cat dog bird", spans)

      assert Align.align("cat dog bird", spans, syllable_ms: :fast) ==
               Align.align("cat dog bird", spans)
    end
  end

  # ---------------------------------------------------------------------------
  # Span-boundary clamping
  # ---------------------------------------------------------------------------

  describe "span-boundary clamping" do
    test "a straddling word goes to the span it overlaps most, and starts there" do
      # T = 400. Weights 1/3/1 over [cat, elephant, dog] give virtual
      # [0,80) [80,320) [320,400). Span A is virtual [0,100), B is [100,400),
      # so `elephant` overlaps A by 20 and B by 220: it belongs to B.
      spans = [span(0, 100), span(1000, 1300)]
      [cat, elephant, dog] = Align.align("cat elephant dog", spans)

      assert_in_delta cat.start_ms, 0.0, @eps
      assert_in_delta cat.end_ms, 80.0, @eps

      assert_in_delta elephant.start_ms, 1000.0, @eps
      assert_in_delta elephant.end_ms, 1220.0, @eps

      assert_in_delta dog.start_ms, 1220.0, @eps
      assert_in_delta dog.end_ms, 1300.0, @eps

      assert Enum.all?([cat, elephant, dog], &inside_a_span?(&1, spans))
    end

    test "when the majority is in the earlier span the word is truncated at its end" do
      # Same weights, T = 400, but A is virtual [0,300): `elephant` overlaps A
      # by 220 and B by 20, so it stays in A and stops at A's edge.
      spans = [span(0, 300), span(1000, 1100)]
      [cat, elephant, dog] = Align.align("cat elephant dog", spans)

      assert_in_delta cat.end_ms, 80.0, @eps
      assert_in_delta elephant.start_ms, 80.0, @eps
      assert_in_delta elephant.end_ms, 300.0, @eps
      assert_in_delta dog.start_ms, 1020.0, @eps
    end

    test "a clamped word is marked down for the allotment it lost" do
      spans = [span(0, 100), span(1000, 1300)]
      [_cat, clamped, _dog] = Align.align("cat elephant dog", spans)
      [_c, whole, _d] = Align.align("cat elephant dog", [span(0, 400)])

      # Same 240 ms of allotment, but the clamped one kept only 220 of it, and
      # it is marked down on both counts: once by the kept fraction, and again
      # because 220 ms is further from a three-syllable word's expectation than
      # 240 ms was.
      assert clamped.confidence < whole.confidence * (220.0 / 240.0)
    end

    test "clamping never puts a word in the silence between spans" do
      spans = [span(0, 100), span(1000, 1300)]

      for word <- Align.align("cat elephant dog", spans) do
        refute word.start_ms > 100.0 and word.start_ms < 1000.0
        refute word.end_ms > 100.0 and word.end_ms < 1000.0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Correction 1: snapping boundaries to energy minima
  # ---------------------------------------------------------------------------

  describe "snapping to energy minima" do
    test "a trough near a boundary pulls the boundary into it" do
      # "cat dog" over 1000 ms puts the only interior boundary at 500.0. Frame
      # 47's centre is 482.5 — 17.5 ms away, well inside the 40 ms window.
      spans = [span(0, 1000)]
      [cat, dog] = Align.align("cat dog", spans, energy: profile(120, [47]))

      assert_in_delta cat.end_ms, centre_of(47), @eps
      assert_in_delta dog.start_ms, centre_of(47), @eps
      assert_in_delta cat.start_ms, 0.0, @eps
      assert_in_delta dog.end_ms, 1000.0, @eps
    end

    test "the two words still share the moved edge exactly" do
      words = Align.align(@ten, [span(0, 1000)], energy: profile(120, [12, 33, 68]))

      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert a.end_ms == b.start_ms end)
    end

    test "a featureless profile changes nothing at all" do
      spans = [span(0, 1000)]

      assert Align.align(@ten, spans, energy: profile(120, [])) == Align.align(@ten, spans)
    end

    test "a profile whose minima are all outside the window changes nothing" do
      # The only quiet frame is at 412.5, which is 87.5 ms from the boundary at
      # 500.0 — more than twice the window.
      spans = [span(0, 1000)]

      assert Align.align("cat dog", spans, energy: profile(120, [40])) ==
               Align.align("cat dog", spans)
    end

    test "boundaries stay in order and words stay positive under a jagged profile" do
      # A dip every third frame: every boundary has somewhere to go, and several
      # of them want to go to the same place.
      dips = Enum.filter(0..119, &(rem(&1, 3) == 0))
      spans = [span(0, 1200)]
      words = Align.align(@ten, spans, energy: profile(130, dips))

      assert length(words) == 10
      assert Enum.all?(words, &(&1.end_ms > &1.start_ms))

      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert a.start_ms < b.start_ms
        assert a.end_ms <= b.start_ms + @eps
      end)
    end

    test "no boundary moves further than :snap_window_ms" do
      spans = [span(0, 1200)]
      dips = Enum.filter(0..119, &(rem(&1, 7) == 0))

      plain = Align.align(@ten, spans)
      snapped = Align.align(@ten, spans, energy: profile(130, dips))

      for {before, after_} <- Enum.zip(plain, snapped) do
        assert abs(before.start_ms - after_.start_ms) <= 40.0 + @eps
        assert abs(before.end_ms - after_.end_ms) <= 40.0 + @eps
      end
    end

    test ":snap_window_ms is the option that bounds it" do
      # Frame 45's centre is 462.5, 37.5 ms from the boundary at 500.0: inside a
      # 40 ms window, outside a 20 ms one.
      spans = [span(0, 1000)]
      energy = profile(120, [45])

      [cat, _dog] = Align.align("cat dog", spans, energy: energy)
      assert_in_delta cat.end_ms, centre_of(45), @eps

      [narrow, _] = Align.align("cat dog", spans, energy: energy, snap_window_ms: 20)
      assert_in_delta narrow.end_ms, 500.0, @eps

      [wide, _] = Align.align("cat dog", spans, energy: energy, snap_window_ms: 60)
      assert_in_delta wide.end_ms, centre_of(45), @eps
    end

    test "a window of zero disables snapping" do
      spans = [span(0, 1000)]

      assert Align.align("cat dog", spans, energy: profile(120, [47]), snap_window_ms: 0) ==
               Align.align("cat dog", spans)
    end

    test "a snapped boundary never lands in the silence between spans" do
      spans = [span(0, 300), span(1000, 1500), span(2400, 2600)]

      transcript =
        "i need you to call me back about the harbor thing tomorrow morning now"

      # Dips everywhere, including all over the silence, so nothing but the
      # span clipping keeps the boundaries out of it.
      words = Align.align(transcript, spans, energy: profile(300, Enum.filter(0..299, &(&1 > 0))))

      assert length(words) > 10

      for word <- words do
        assert inside_a_span?(word, spans),
               "#{word.text} at #{word.start_ms}..#{word.end_ms} escaped its span"
      end
    end

    test "a boundary is clipped to its own span rather than crossing into the next" do
      # T = 400 over two spans. `cat elephant dog` weighted 1/3/1 puts boundaries
      # at virtual 80 and 320; span A is virtual [0,100). Frame 11's centre is
      # 122.5, which is past A's edge in virtual terms, so the boundary at 80
      # cannot reach it however quiet it is.
      spans = [span(0, 100), span(1000, 1300)]
      opts = [energy: profile(200, [11]), reduce_function_words: false]

      for word <- Align.align("cat elephant dog", spans, opts) do
        assert inside_a_span?(word, spans)
        refute word.start_ms > 100.0 and word.start_ms < 1000.0
        refute word.end_ms > 100.0 and word.end_ms < 1000.0
      end
    end

    test "a snap that would crush a word below :min_word_ms is refused" do
      # Three equal words over 300 ms: boundaries at 100.0 and 200.0, every word
      # 100 ms. The trough is at 132.5 — 32.5 ms away, inside the 40 ms window —
      # but taking it would leave the middle word 67.5 ms.
      spans = [span(0, 300)]
      energy = profile(40, [12])

      [cat, dog, _bird] = Align.align("cat dog bird", spans, energy: energy, min_word_ms: 90)

      assert_in_delta cat.end_ms, 100.0, @eps
      assert_in_delta dog.end_ms - dog.start_ms, 100.0, @eps

      # It is the minimum doing the refusing, not the window: drop the floor and
      # the very same boundary reaches the very same trough.
      [reached, _, _] = Align.align("cat dog bird", spans, energy: energy, min_word_ms: 10)
      assert_in_delta reached.end_ms, centre_of(12), @eps
    end

    test "a word already shorter than :min_word_ms is never lengthened, only left alone" do
      # Twenty words over 400 ms is 20 ms each — every one already under any
      # sane minimum. The rule must not deadlock or invent time.
      spans = [span(0, 400)]
      transcript = 1..20 |> Enum.map_join(" ", fn _ -> "cat" end)
      words = Align.align(transcript, spans, energy: profile(60, [3, 9, 17, 25, 31]))

      assert length(words) == 20
      assert Enum.all?(words, &(&1.end_ms > &1.start_ms))
      assert_in_delta allotted_ms(words), 400.0, 1.0e-6

      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert a.end_ms == b.start_ms end)
    end

    test "the first and last boundaries are never moved: they are the speech edges" do
      spans = [span(0, 1000)]
      dips = Enum.filter(0..119, &(rem(&1, 2) == 0))
      words = Align.align(@ten, spans, energy: profile(130, dips))

      assert_in_delta List.first(words).start_ms, 0.0, @eps
      assert_in_delta List.last(words).end_ms, 1000.0, @eps
      assert_in_delta allotted_ms(words), 1000.0, 1.0e-6
    end

    test "ties go to the frame nearest the original boundary, not the earliest" do
      spans = [span(0, 1000)]

      # Equal minima at 482.5 (17.5 ms early) and 532.5 (32.5 ms late).
      [a, _] = Align.align("cat dog", spans, energy: profile(120, [47, 52]))
      assert_in_delta a.end_ms, centre_of(47), @eps

      # And the other way round: 512.5 (12.5 ms late) beats 472.5 (27.5 ms
      # early), so this is not "the first one found".
      [b, _] = Align.align("cat dog", spans, energy: profile(120, [46, 51]))
      assert_in_delta b.end_ms, centre_of(51), @eps
    end

    test "an exact tie in both energy and distance goes to the earlier frame" do
      # A 995 ms span puts the boundary at 497.5, exactly between two frame
      # centres, so the minima at 482.5 and 512.5 are both 15 ms away.
      spans = [span(0, 995)]
      [a, _] = Align.align("cat dog", spans, energy: profile(120, [47, 50]))

      assert_in_delta a.end_ms, centre_of(47), @eps
    end

    test "a boundary already in the trough does not shuffle out of it" do
      # A 1005 ms span puts the boundary at 502.5, which is frame 49's centre —
      # and frame 49 is the trough. There is nothing quieter to move to, so it
      # must stay put rather than slide to a neighbouring frame.
      spans = [span(0, 1005)]

      assert Align.align("cat dog", spans, energy: profile(120, [49])) ==
               Align.align("cat dog", spans)

      [cat, _] = Align.align("cat dog", spans, energy: profile(120, [49]))
      assert_in_delta cat.end_ms, centre_of(49), @eps
    end
  end

  describe "snapping: profiles that cannot be trusted" do
    test "a frame_count that disagrees with the frames is ignored, not believed" do
      spans = [span(0, 1000)]
      honest = profile(120, [47])
      lying = %{honest | frame_count: 99_999, duration_ms: 999_999.0}

      assert Align.align("cat dog", spans, energy: lying) ==
               Align.align("cat dog", spans, energy: honest)
    end

    test "a frame_count smaller than the frame list does not truncate the search" do
      spans = [span(0, 1000)]
      honest = profile(120, [47])

      assert Align.align("cat dog", spans, energy: %{honest | frame_count: 3}) ==
               Align.align("cat dog", spans, energy: honest)
    end

    test "a profile covering a different, shorter recording simply finds nothing" do
      # Ten frames is 125 ms of analysis against a 1000 ms span: the window
      # around the boundary at 500 contains no frame at all.
      spans = [span(0, 1000)]

      assert Align.align("cat dog", spans, energy: profile(10, [3])) ==
               Align.align("cat dog", spans)
    end

    test "frames missing their measurements are dropped, not defaulted to zero" do
      spans = [span(0, 1000)]
      full = profile(120, [47])

      maimed = %{
        full
        | frames:
            Enum.map(full.frames, fn
              %{index: 49} = frame -> Map.delete(frame, :rms)
              %{index: 50} = frame -> %{frame | rms: nil}
              frame -> frame
            end)
      }

      # A dropped frame is not a silent frame: the trough at 47 still wins.
      [cat, _] = Align.align("cat dog", spans, energy: maimed)
      assert_in_delta cat.end_ms, centre_of(47), @eps
    end

    test "an unusable :energy value falls back to no snapping rather than failing" do
      spans = [span(0, 1000)]
      plain = Align.align(@ten, spans)

      for junk <- [nil, :profile, %{}, %{frames: :none}, %{frames: [nil, :frame, %{}]}, [], 42] do
        assert Align.align(@ten, spans, energy: junk) == plain
      end
    end

    test "an unusable :snap_window_ms or :min_word_ms falls back to the default" do
      spans = [span(0, 1000)]
      energy = profile(120, [47])
      snapped = Align.align("cat dog", spans, energy: energy)

      assert Align.align("cat dog", spans, energy: energy, snap_window_ms: :wide) == snapped
      assert Align.align("cat dog", spans, energy: energy, snap_window_ms: -5) == snapped
      assert Align.align("cat dog", spans, energy: energy, min_word_ms: :long) == snapped
    end
  end

  # ---------------------------------------------------------------------------
  # Correction 2: reducing function words
  # ---------------------------------------------------------------------------

  describe "function words" do
    test "a function word gets less time than a content word of the same syllable count" do
      # `the` and `cat` are both one syllable; only one of them is spoken like a
      # full beat. 0.55 against 1.0 over 310 ms.
      [the, cat] = Align.align("the cat", [span(0, 310)])

      assert the.end_ms - the.start_ms < cat.end_ms - cat.start_ms
      assert_in_delta the.end_ms - the.start_ms, 110.0, 1.0e-9
      assert_in_delta cat.end_ms - cat.start_ms, 200.0, 1.0e-9
    end

    test "the reduction is on by default" do
      spans = [span(0, 310)]

      assert Align.align("the cat", spans) ==
               Align.align("the cat", spans, reduce_function_words: true)

      refute Align.align("the cat", spans) ==
               Align.align("the cat", spans, reduce_function_words: false)
    end

    test "the multiplier is applied before normalisation, so no time is lost" do
      # The reduction redistributes time; it does not throw any away. One span,
      # so nothing is lost to boundary clamping either and the total is exact.
      spans = [span(0, 1500)]

      transcript =
        "hi it is me again i wanted to check in about the thing we talked " <>
          "about on friday please call me back when you get a chance thanks"

      words = Align.align(transcript, spans)

      assert length(words) == 28
      assert_in_delta allotted_ms(words), total_span_ms(spans), 1.0e-6

      # And the same total with the correction off, so this is conservation and
      # not a coincidence of one arrangement.
      off = Align.align(transcript, spans, reduce_function_words: false)
      assert_in_delta allotted_ms(off), total_span_ms(spans), 1.0e-6
      refute Enum.map(words, & &1.start_ms) == Enum.map(off, & &1.start_ms)
    end

    test "a transcript of nothing but function words is shared out evenly, not shrunk" do
      # Every weight scaled by the same factor normalises back to the same
      # shares — which is the proof that the multiplier is relative. The TIMES
      # are identical; the confidences are not, and should not be. Four words of
      # pure function taking 200 ms each is exactly the implausible reading this
      # module's confidence exists to report, and the reduction is what makes it
      # visible instead of scoring a flat 0.9.
      spans = [span(0, 800)]
      reduced = Align.align("to the of by", spans)
      plain = Align.align("to the of by", spans, reduce_function_words: false)

      assert Enum.map(reduced, &{&1.word, &1.start_ms, &1.end_ms}) ==
               Enum.map(plain, &{&1.word, &1.start_ms, &1.end_ms})

      assert Enum.all?(reduced, &(&1.confidence < 0.7))
      assert Enum.all?(plain, &(&1.confidence > 0.85))
    end

    test "the function word stops eating its neighbour's onset" do
      # The concrete complaint: `to` was taking a full syllable's share out of
      # the stressed word beside it.
      spans = [span(0, 1000)]

      [_, plain_shop] = Align.align("to shop", spans, reduce_function_words: false)
      [_, fixed_shop] = Align.align("to shop", spans)

      assert fixed_shop.end_ms - fixed_shop.start_ms >
               plain_shop.end_ms - plain_shop.start_ms + 100.0
    end

    test ":function_word_scale is the option that tunes it" do
      spans = [span(0, 300)]

      [half, _cat] = Align.align("the cat", spans, function_word_scale: 0.5)
      assert_in_delta half.end_ms - half.start_ms, 100.0, 1.0e-9

      [tenth, _] = Align.align("the cat", spans, function_word_scale: 0.1)
      assert_in_delta tenth.end_ms - tenth.start_ms, 300.0 * 0.1 / 1.1, 1.0e-9
    end

    test "an unusable :function_word_scale falls back to the default" do
      spans = [span(0, 310)]
      default = Align.align("the cat", spans)

      for junk <- [0, -1, 1.5, 2, :half, nil] do
        assert Align.align("the cat", spans, function_word_scale: junk) == default
      end

      # 1.0 is legal and means exactly "no reduction".
      assert Align.align("the cat", spans, function_word_scale: 1.0) ==
               Align.align("the cat", spans, reduce_function_words: false)
    end

    test ":function_word_scale is ignored when the reduction is off" do
      spans = [span(0, 310)]

      assert Align.align("the cat", spans, reduce_function_words: false, function_word_scale: 0.1) ==
               Align.align("the cat", spans, reduce_function_words: false)
    end

    test "contractions that survive normalisation are recognised" do
      # `don't` normalises to `dont`, which is in the set; `harbor` is not.
      [dont, harbor] = Align.align("don't harbor", [span(0, 1000)])

      assert dont.end_ms - dont.start_ms < harbor.end_ms - harbor.start_ms
    end

    test "words that only look functional are left alone" do
      # Negations, wh-words, deictics and short content words are stressed, and
      # are deliberately not in the set.
      spans = [span(0, 400)]

      for word <- ~w(not no never what when while where who why how this that there now back) do
        assert Align.align("#{word} cat", spans) ==
                 Align.align("#{word} cat", spans, reduce_function_words: false),
               "#{word} is being reduced and should not be"
      end
    end

    test "a reduced word is not marked down for obeying the model that reduced it" do
      # The expectation is scaled by the same multiplier, so under syllable
      # weighting every word in one call still scores identically — the property
      # the moduledoc claims, preserved through the correction.
      words = Align.align("the cat sat on the mat", [span(0, 1000)])

      assert length(words) == 6
      [first | rest] = words
      assert Enum.all?(rest, &(abs(&1.confidence - first.confidence) < 1.0e-9))
    end

    test "the reduction shows up in confidence only through the shares it moved" do
      # A content word beside function words now gets closer to a real duration,
      # and its confidence rises accordingly.
      spans = [span(0, 600)]

      [_, _, plain] = Align.align("the a harbor", spans, reduce_function_words: false)
      [_, _, fixed] = Align.align("the a harbor", spans)

      assert fixed.confidence > plain.confidence
    end
  end

  # ---------------------------------------------------------------------------
  # The A/B pin. Both corrections off must reproduce the old module byte for
  # byte, or there is nothing to compare the new one against.
  # ---------------------------------------------------------------------------

  describe "both corrections off" do
    test "reproduces the pre-correction output exactly" do
      # Captured from the module as it stood before either correction existed.
      # Two spans with a straddle in the middle (`call` is clamped at 400.0 and
      # `me` restarts at 1034.6), a transcript that is more than half function
      # words, and confidences carried to the last digit.
      expected = [
        {"i", 0.0, 86.92307692307692, 0.43692683133235877},
        {"need", 86.92307692307692, 173.84615384615384, 0.43692683133235877},
        {"you", 173.84615384615384, 260.7692307692308, 0.4369268313323588},
        {"to", 260.7692307692308, 347.6923076923077, 0.4369268313323585},
        {"call", 347.6923076923077, 400.0, 0.08331145251380004},
        {"me", 1034.6153846153848, 1121.5384615384614, 0.4369268313323554},
        {"back", 1121.5384615384614, 1208.4615384615386, 0.4369268313323606},
        {"about", 1208.4615384615386, 1382.3076923076924, 0.4369268313323585},
        {"the", 1382.3076923076924, 1469.2307692307693, 0.43692683133235793},
        {"harbor", 1469.2307692307693, 1643.076923076923, 0.4369268313323585},
        {"thing", 1643.076923076923, 1730.0, 0.4369268313323585}
      ]

      spans = [span(0, 400), span(1000, 1730)]
      transcript = "i need you to call me back about the harbor thing"

      opts = [reduce_function_words: false, snap_to_energy: false]
      words = Align.align(transcript, spans, opts)

      assert Enum.map(words, &{&1.word, &1.start_ms, &1.end_ms, &1.confidence}) == expected
    end

    test "`snap_to_energy: false` ignores a profile that would otherwise move things" do
      spans = [span(0, 1000)]
      energy = profile(120, [47])

      refute Align.align("cat dog", spans, energy: energy) == Align.align("cat dog", spans)

      assert Align.align("cat dog", spans, energy: energy, snap_to_energy: false) ==
               Align.align("cat dog", spans)
    end

    test "the four combinations are four distinct outputs" do
      spans = [span(0, 1000)]
      energy = profile(120, Enum.filter(0..119, &(rem(&1, 5) == 0)))
      transcript = "i need to call the harbor about the thing"

      outputs =
        for snap <- [false, true], reduce <- [false, true] do
          Align.align(transcript, spans,
            energy: energy,
            snap_to_energy: snap,
            reduce_function_words: reduce
          )
        end

      assert length(Enum.uniq(outputs)) == 4
    end

    test "each correction is inert without the other" do
      spans = [span(0, 1000)]
      transcript = "i need to call the harbor about the thing"

      # Reduction alone is exactly the default with no profile in the call.
      assert Align.align(transcript, spans, snap_to_energy: true) ==
               Align.align(transcript, spans)

      # Snapping alone leaves the shares proportional: the same total, and the
      # same words, as reduction-off with no profile.
      snap_only =
        Align.align(transcript, spans,
          energy: profile(120, [47]),
          reduce_function_words: false
        )

      plain = Align.align(transcript, spans, reduce_function_words: false)

      assert Enum.map(snap_only, & &1.word) == Enum.map(plain, & &1.word)
      assert_in_delta allotted_ms(snap_only), allotted_ms(plain), 1.0e-6
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases. None of these raise.
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "an empty or whitespace transcript aligns to nothing" do
      assert Align.align("", [span(0, 1000)]) == []
      assert Align.align("   \n\t ", [span(0, 1000)]) == []
    end

    test "a transcript that is only punctuation aligns to nothing" do
      assert Align.align("... --- ,,, ??", [span(0, 1000)]) == []
    end

    test "punctuation tokens do not consume audio from the words around them" do
      with_noise = Align.align("cat -- dog", [span(0, 1000)])
      without = Align.align("cat dog", [span(0, 1000)])

      assert with_noise == without
    end

    test "no spans, empty spans, and unusable spans all align to nothing" do
      assert Align.align("cat dog", []) == []
      assert Align.align("cat dog", [span(500, 500)]) == []
      assert Align.align("cat dog", [%{start_ms: 300.0, end_ms: 100.0, frames: 1}]) == []
      assert Align.align("cat dog", [%{start_ms: -100.0, end_ms: 100.0, frames: 1}]) == []
      assert Align.align("cat dog", [%{}, :nonsense, nil]) == []
      assert Align.align("cat dog", [%{start_ms: "0", end_ms: "1000", frames: 1}]) == []
    end

    test "one span is not a special case" do
      assert [%{start_ms: 100.0, end_ms: 200.0}] = Align.align("cat", [span(100, 200)])
    end

    test "usable spans survive unusable neighbours" do
      spans = [span(0, 500), %{start_ms: 700.0, end_ms: 700.0, frames: 1}, :junk]
      assert [_cat, _dog] = words = Align.align("cat dog", spans)
      assert allotted_ms(words) == 500.0
    end

    test "non-binary and non-list arguments return an empty list" do
      assert Align.align(nil, [span(0, 1000)]) == []
      assert Align.align(:cat, [span(0, 1000)]) == []
      assert Align.align("cat", :spans) == []
      assert Align.align("cat", [span(0, 1000)], :opts) == []
    end

    test "more words than milliseconds still produces ordered entries inside the span" do
      spans = [span(0, 1000)]
      transcript = 1..2000 |> Enum.map_join(" ", fn _ -> "cat" end)
      words = Align.align(transcript, spans)

      assert length(words) == 2000
      assert Enum.all?(words, &(&1.end_ms > &1.start_ms))
      assert Enum.all?(words, &inside_a_span?(&1, spans))
      assert_in_delta allotted_ms(words), 1000.0, 1.0e-6
    end

    test "apostrophes and digits survive as text and normalise for matching" do
      words = Align.align("o'clock 1997 don't", [span(0, 900)])

      assert Enum.map(words, & &1.text) == ["o'clock", "1997", "don't"]
      assert Enum.map(words, & &1.word) == ["oclock", "1997", "dont"]
    end

    test "the corpus's own mangling aligns without complaint" do
      # Twilio hears "Buster Claw" as "bus o'clock"; the aligner has no way to
      # know and places both words happily. Documented, not fixed.
      words = Align.align("call bus o'clock back", [span(0, 1200)])

      assert Enum.map(words, & &1.word) == ["call", "bus", "oclock", "back"]
    end

    test "far more words than spans is the ordinary case, not a failure" do
      spans = [span(0, 900), span(2000, 2600)]

      transcript =
        "hi it is me again i wanted to check in about the thing we talked " <>
          "about on friday please call me back when you get a chance thanks"

      words = Align.align(transcript, spans)

      assert length(words) == 28
      assert Enum.all?(words, &inside_a_span?(&1, spans))
    end

    test "unicode words are tokens like any other" do
      words = Align.align("café größe", [span(0, 600)])

      assert Enum.map(words, & &1.text) == ["café", "größe"]
      assert Enum.map(words, & &1.word) == ["café", "größe"]
    end

    test "overlapping spans never hand the same millisecond to two words" do
      spans = [span(0, 600), span(400, 1000), span(450, 500)]
      words = Align.align(@ten, spans)

      assert length(words) == 10
      assert_in_delta allotted_ms(words), 1000.0, 1.0e-6

      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert a.end_ms <= b.start_ms + @eps end)
    end

    test "spans given out of order are sorted before the timeline is built" do
      shuffled = [span(2000, 2500), span(0, 500)]

      assert Align.align(@ten, shuffled) == Align.align(@ten, Enum.reverse(shuffled))
    end
  end
end
