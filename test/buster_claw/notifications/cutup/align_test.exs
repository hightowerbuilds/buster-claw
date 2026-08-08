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
  # checkable by hand.
  @ten "cat dog bird fish tree bee ant cow fox hen"

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
    test "a polysyllabic word gets more time than a monosyllable in the same span" do
      [a, elephant] = Align.align("a elephant", [span(0, 400)])

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
      [a, elephant] = Align.align("a elephant", [span(0, 900)], weight: :characters)

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
