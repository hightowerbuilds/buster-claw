defmodule BusterClaw.Notifications.Cutup.DtwTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Cutup.Dtw

  doctest BusterClaw.Notifications.Cutup.Dtw

  @dim 13
  @eps 1.0e-9

  describe "distance/3 — the foundation" do
    test "a sequence against itself is exactly zero" do
      seq = seq(40, 1)

      assert Dtw.distance(seq, seq) == 0.0
    end

    test "a one-frame sequence against itself is zero" do
      assert Dtw.distance([[1.0, 2.0, 3.0]], [[1.0, 2.0, 3.0]]) == 0.0
    end

    test "it is symmetric, which the symmetric step weights are what buy" do
      a = seq(30, 7)
      b = seq(45, 9)

      assert_in_delta Dtw.distance(a, b), Dtw.distance(b, a), @eps
    end

    test "the normalised distance is the mean local frame distance" do
      # Every pair of frames is exactly 3.0 apart, so every path — whatever mix
      # of diagonal and axis moves it takes — must normalise to exactly 3.0.
      # This pins both the weighting and the division: with the weights and the
      # path length out of step the answer would drift with the shape.
      a = List.duplicate([0.0], 5)
      b = List.duplicate([3.0], 7)

      assert_in_delta Dtw.distance(a, b), 3.0, @eps
    end

    test "the path weight for full DTW is exactly m + n" do
      # cost = mean_local_distance * weight, and with every local distance equal
      # to 2.0 the recoverable total is 2.0 * (m + n). Multiplying the returned
      # normalised distance back out and getting that number is how the
      # invariant is observable from outside.
      a = List.duplicate([0.0], 6)
      b = List.duplicate([2.0], 11)

      assert_in_delta Dtw.distance(a, b) * (6 + 11), 2.0 * (6 + 11), @eps
    end

    test "a stretched copy is distance zero — the whole reason for DTW" do
      seq = seq(25, 3)

      assert Dtw.distance(seq, stretch(seq, 2)) == 0.0
      assert Dtw.distance(seq, stretch(seq, 3)) == 0.0
    end

    test "an unrelated sequence scores well above a warped copy of itself" do
      seq = seq(25, 3)

      assert Dtw.distance(seq, stretch(seq, 2)) < Dtw.distance(seq, seq(25, 99))
    end

    test "length normalisation: a 20-frame and a 60-frame pair perturbed the same score the same" do
      short = seq(20, 11)
      long = seq(60, 13)

      short_d = Dtw.distance(short, offset(short, 0.02))
      long_d = Dtw.distance(long, offset(long, 0.02))

      expected = 0.02 * :math.sqrt(@dim)

      assert_in_delta short_d, expected, 1.0e-6
      assert_in_delta long_d, expected, 1.0e-6

      # And this is what would happen without the division: the accumulated
      # totals differ by exactly the length ratio, so one threshold could not
      # possibly serve both words.
      short_total = short_d * (20 + 20)
      long_total = long_d * (60 + 60)

      assert_in_delta long_total / short_total, 3.0, 1.0e-6
    end
  end

  describe "distance/3 — degenerate input" do
    test "an empty first sequence is a named error" do
      assert Dtw.distance([], [[1.0]]) == {:error, :empty_template}
    end

    test "an empty second sequence is a named error" do
      assert Dtw.distance([[1.0]], []) == {:error, :empty_target}
    end

    test "mismatched feature dimensions are a named error" do
      assert Dtw.distance([[1.0, 2.0]], [[1.0]]) == {:error, :ragged_features}
    end

    test "a longer first sequence is fine for full DTW" do
      assert is_float(Dtw.distance(seq(30, 1), seq(5, 2)))
    end

    test "nothing raises on rubbish" do
      assert Dtw.distance(:nope, [[1.0]]) == {:error, :not_a_sequence}
      assert Dtw.distance([[1.0]], "nope") == {:error, :not_a_sequence}
      assert Dtw.distance([["a"]], [[1.0]]) == {:error, :not_a_sequence}
      assert Dtw.distance([[]], [[1.0]]) == {:error, :not_a_sequence}
    end
  end

  describe "search/3 — locating a template" do
    test "a verbatim copy is found at exactly the right frame offset" do
      template = seq(24, 21)
      target = seq(37, 5) ++ template ++ seq(60, 6)

      assert [match] = Dtw.search(template, target, threshold: @eps)
      assert match.start_frame == 37
      assert match.end_frame == 37 + 24 - 1
      assert match.distance == 0.0
    end

    test "the millisecond fields follow the 10 ms hop" do
      template = seq(10, 31)
      target = seq(20, 5) ++ template ++ seq(20, 6)

      assert [match] = Dtw.search(template, target, threshold: @eps)
      assert match.start_ms == 200.0
      assert match.end_ms == 300.0
    end

    test "a match at the very start of the target is found" do
      template = seq(15, 41)
      target = template ++ seq(50, 8)

      assert [match] = Dtw.search(template, target, threshold: @eps)
      assert match.start_frame == 0
    end

    test "a match at the very end of the target is found" do
      template = seq(15, 43)
      target = seq(50, 8) ++ template

      assert [match] = Dtw.search(template, target, threshold: @eps)
      assert match.start_frame == 50
      assert match.end_frame == 64
    end

    test "a template searched against itself matches at offset zero with distance zero" do
      template = seq(30, 17)

      assert [match] = Dtw.search(template, template, threshold: @eps)
      assert match.start_frame == 0
      assert match.end_frame == 29
      assert match.distance == 0.0
    end

    test "the returned shape is a Types.match" do
      template = seq(12, 51)
      target = seq(20, 5) ++ template ++ seq(20, 6)

      assert [match] = Dtw.search(template, target, threshold: @eps)

      assert %{
               start_frame: _,
               end_frame: _,
               start_ms: _,
               end_ms: _,
               distance: _
             } = match

      assert map_size(match) == 5
    end
  end

  describe "search/3 — time-warp invariance" do
    test "a stretched instance is found with distance zero — the whole point of DTW" do
      # If this fails the module has no reason to exist: correlation would do.
      template = seq(20, 23)
      target = seq(30, 5) ++ stretch(template, 2) ++ seq(30, 6)

      assert [match] = Dtw.search(template, target, threshold: @eps)
      assert match.distance == 0.0
      assert match.start_frame >= 30
      assert match.end_frame <= 69
    end

    test "a stretched instance reports its tightest zero-cost core, not its outer edges" do
      # Two behaviours pinned here because both surprise, and both are edge
      # trimming of (factor - 1) frames:
      #
      # * the onset lands on the LAST duplicate of the first template frame,
      #   because the free-start row is a free start and nothing else — letting
      #   the first template frame stretch horizontally would also let a silent
      #   run inflate the path length and deflate every score in the recording;
      # * the offset lands on the FIRST duplicate of the last template frame,
      #   because every column from there on ties at zero and ties resolve to
      #   the shortest span.
      #
      # That is 10 ms per stretch factor at each edge, comfortably inside the
      # 30 ms Assemble pads outward by before it cuts.
      template = seq(20, 23)

      assert [two] =
               Dtw.search(template, seq(30, 5) ++ stretch(template, 2) ++ seq(30, 6),
                 threshold: @eps
               )

      assert [three] =
               Dtw.search(template, seq(30, 5) ++ stretch(template, 3) ++ seq(30, 6),
                 threshold: @eps
               )

      assert {two.start_frame, two.end_frame} == {31, 68}
      assert {three.start_frame, three.end_frame} == {32, 87}
    end

    test "a compressed instance is still found, warping the other way" do
      # The mirror of the case above: the template is the slow take and the
      # recording holds the fast one, so the template must fold two of its
      # frames onto one target frame.
      base = seq(20, 25)
      template = stretch(base, 2)
      target = seq(25, 5) ++ base ++ seq(25, 6)

      assert [match] = Dtw.search(template, target, threshold: @eps)
      assert match.start_frame == 25
      assert match.end_frame == 25 + 20 - 1
      assert match.distance == 0.0
    end

    test "a stretched instance beats an unrelated span by a wide margin" do
      template = seq(20, 27)
      target = seq(40, 5) ++ stretch(template, 2) ++ seq(40, 6)

      assert [best | _] = Dtw.search(template, target, limit: 3)
      others = Dtw.search(template, target, limit: 3) |> Enum.drop(1)

      assert best.distance == 0.0
      assert Enum.all?(others, &(&1.distance > 0.3))
    end
  end

  describe "search/3 — length normalisation across template lengths" do
    test "a 20-frame and a 60-frame template perturbed identically score comparably" do
      short = seq(20, 61)
      long = seq(60, 63)

      short_target = seq(40, 5) ++ offset(short, 0.02) ++ seq(40, 6)
      long_target = seq(40, 7) ++ offset(long, 0.02) ++ seq(40, 8)

      assert [short_hit] = Dtw.search(short, short_target, limit: 1)
      assert [long_hit] = Dtw.search(long, long_target, limit: 1)

      assert short_hit.start_frame == 40
      assert long_hit.start_frame == 40

      ratio = long_hit.distance / short_hit.distance
      assert ratio > 0.5 and ratio < 2.0

      # Both should sit near the mean local distance the perturbation creates,
      # independent of how many frames long the word is. That independence is
      # the property a single tuned threshold depends on.
      expected = 0.02 * :math.sqrt(@dim)
      assert_in_delta short_hit.distance, expected, 0.02
      assert_in_delta long_hit.distance, expected, 0.02
    end

    test "a pseudo-random perturbation of the same scale also scores comparably" do
      short = seq(20, 71)
      long = seq(60, 73)

      short_target = seq(40, 5) ++ jitter(short, 0.05, 101) ++ seq(40, 6)
      long_target = seq(40, 7) ++ jitter(long, 0.05, 103) ++ seq(40, 8)

      assert [short_hit] = Dtw.search(short, short_target, limit: 1)
      assert [long_hit] = Dtw.search(long, long_target, limit: 1)

      ratio = long_hit.distance / short_hit.distance
      assert ratio > 0.5 and ratio < 2.0
    end

    test "the score barely moves across a 4x range of template lengths" do
      # The tightest statement of the property the whole normalisation exists
      # for: one perturbation scale, four template lengths, one number. If the
      # division by path length were wrong these would spread by 4x and no
      # single :threshold could serve a short word and a long one.
      scores =
        for m <- [20, 40, 60, 80] do
          template = seq(m, 300 + m)
          target = seq(60, 5) ++ jitter(template, 0.1, 55) ++ seq(60, 6)

          assert [hit] = Dtw.search(template, target, limit: 1)
          assert hit.start_frame == 60
          hit.distance
        end

      spread = Enum.max(scores) / Enum.min(scores)
      assert spread < 1.1, "expected length-independent scores, got #{inspect(scores)}"
    end
  end

  describe "search/3 — separation, which is what makes a threshold findable" do
    test "the best score in a target that does not contain the template is far above a true hit" do
      # This is the tuning recipe in the moduledoc, run as a test: the
      # false-alarm floor has to sit well above the hit ceiling or no threshold
      # exists at all.
      template = seq(40, 201)

      assert [false_alarm] = Dtw.search(template, seq(1200, 202), limit: 1)

      assert [hit] =
               Dtw.search(template, seq(80, 5) ++ jitter(template, 0.1, 9) ++ seq(80, 6),
                 limit: 1
               )

      assert hit.distance < false_alarm.distance / 5
    end

    test "the false-alarm floor does not sag as the recording gets longer" do
      # If it did, a threshold would have to be re-tuned per recording length,
      # which is the same trap as re-tuning it per word.
      template = seq(40, 203)

      floors =
        for n <- [1_000, 4_000, 16_000] do
          assert [best] = Dtw.search(template, seq(n, 204), limit: 1)
          best.distance
        end

      assert Enum.max(floors) / Enum.min(floors) < 1.25
    end
  end

  describe "search/3 — non-overlapping results" do
    test "three instances yield exactly three matches at the right offsets" do
      template = seq(20, 81)
      gap = seq(30, 5)

      target = gap ++ template ++ gap ++ template ++ gap ++ template ++ gap

      matches = Dtw.search(template, target, threshold: @eps, limit: :infinity)

      assert length(matches) == 3
      assert Enum.map(matches, & &1.start_frame) |> Enum.sort() == [30, 80, 130]
      assert Enum.all?(matches, &(&1.distance == 0.0))
    end

    test "reported spans never overlap" do
      template = seq(18, 83)
      target = seq(25, 5) ++ template ++ seq(25, 6) ++ template ++ seq(25, 7)

      matches =
        Dtw.search(template, target, limit: :infinity, threshold: 0.5)
        |> Enum.sort_by(& &1.start_frame)

      pairs = Enum.zip(matches, tl(matches))
      assert Enum.all?(pairs, fn {a, b} -> a.end_frame < b.start_frame end)
    end

    test "min_gap_frames widens the exclusion zone" do
      template = seq(20, 85)
      gap = seq(30, 5)
      target = gap ++ template ++ gap ++ template ++ gap ++ template ++ gap

      # Instances start 50 frames apart. A 60-frame minimum gap keeps the first
      # and the last and drops the middle one.
      matches =
        Dtw.search(template, target,
          threshold: @eps,
          limit: :infinity,
          min_gap_frames: 60
        )

      assert length(matches) == 2
      assert Enum.map(matches, & &1.start_frame) |> Enum.sort() == [30, 130]
    end

    test "back-to-back instances are both reported at the default gap" do
      template = seq(20, 87)
      target = seq(10, 5) ++ template ++ template ++ seq(10, 6)

      matches = Dtw.search(template, target, threshold: @eps, limit: :infinity)

      assert Enum.map(matches, & &1.start_frame) |> Enum.sort() == [10, 30]
    end

    test "a single instance does not report five overlapping hits" do
      template = seq(30, 89)
      target = seq(40, 5) ++ template ++ seq(40, 6)

      assert [_only_one] = Dtw.search(template, target, threshold: 0.2, limit: :infinity)
    end
  end

  describe "search/3 — threshold and limit" do
    test "the threshold filters out the poorer instance" do
      template = seq(20, 91)
      exact = template
      rough = offset(template, 0.3)
      target = seq(40, 5) ++ exact ++ seq(40, 6) ++ rough ++ seq(40, 7)

      loose = Dtw.search(template, target, threshold: 2.0, limit: :infinity)
      tight = Dtw.search(template, target, threshold: 0.01, limit: :infinity)

      assert length(loose) == 2
      assert [only] = tight
      assert only.start_frame == 40
    end

    test "a threshold nothing can meet returns an empty list" do
      template = seq(20, 93)
      target = seq(40, 5) ++ template ++ seq(40, 6)

      assert Dtw.search(template, target, threshold: -1.0) == []
    end

    test "the limit truncates the best-first list" do
      template = seq(20, 95)
      gap = seq(30, 5)
      target = gap ++ template ++ gap ++ template ++ gap ++ template ++ gap

      assert length(Dtw.search(template, target, threshold: @eps, limit: :infinity)) == 3
      assert length(Dtw.search(template, target, threshold: @eps, limit: 2)) == 2
      assert length(Dtw.search(template, target, threshold: @eps, limit: 1)) == 1
    end

    test "results come back best first" do
      template = seq(20, 97)

      target =
        seq(30, 5) ++
          offset(template, 0.3) ++
          seq(30, 6) ++ template ++ seq(30, 7) ++ offset(template, 0.1) ++ seq(30, 8)

      matches = Dtw.search(template, target, limit: 3)
      distances = Enum.map(matches, & &1.distance)

      assert distances == Enum.sort(distances)
      assert hd(matches).distance == 0.0
    end
  end

  describe "search/3 — degenerate input" do
    test "an empty template returns an empty list, not a raise" do
      assert Dtw.search([], seq(10, 1)) == []
    end

    test "an empty target returns an empty list" do
      assert Dtw.search(seq(10, 1), []) == []
    end

    test "a template longer than the target returns an empty list" do
      assert Dtw.search(seq(40, 1), seq(10, 2)) == []
    end

    test "mismatched feature dimensions return an empty list" do
      assert Dtw.search([[1.0, 2.0]], [[1.0], [2.0], [3.0]]) == []
    end

    test "ragged vectors within one sequence return an empty list" do
      assert Dtw.search([[1.0, 2.0]], [[1.0, 2.0], [3.0]]) == []
    end

    test "non-sequences return an empty list" do
      assert Dtw.search(nil, seq(10, 1)) == []
      assert Dtw.search(seq(10, 1), %{}) == []
      assert Dtw.search([[:a]], seq(10, 1)) == []
    end
  end

  describe "validate/3 — the named errors search/3 swallows" do
    test "it names every refusal" do
      assert Dtw.validate([], [[1.0]]) == {:error, :empty_template}
      assert Dtw.validate([[1.0]], []) == {:error, :empty_target}
      assert Dtw.validate([[1.0], [2.0]], [[1.0]]) == {:error, :template_longer_than_target}
      assert Dtw.validate([[1.0, 2.0]], [[1.0], [2.0]]) == {:error, :ragged_features}
      assert Dtw.validate("no", [[1.0]]) == {:error, :not_a_sequence}
    end

    test "the length check is relaxed for :distance" do
      assert Dtw.validate([[1.0], [2.0]], [[1.0]], :distance) == :ok

      assert Dtw.validate([[1.0], [2.0]], [[1.0]], :search) ==
               {:error, :template_longer_than_target}
    end

    test "a well-formed pair passes" do
      assert Dtw.validate(seq(5, 1), seq(20, 2)) == :ok
    end
  end

  describe "options" do
    test "the metric is swappable and a custom function is honoured" do
      a = [[0.0, 0.0]]
      b = [[3.0, 4.0]]

      assert_in_delta Dtw.distance(a, b, metric: :euclidean), 5.0, @eps
      assert_in_delta Dtw.distance(a, b, metric: :manhattan), 7.0, @eps
      assert_in_delta Dtw.distance(a, b, metric: fn _x, _y -> 1.5 end), 1.5, @eps
    end

    test "cosine ignores magnitude, which euclidean does not" do
      a = [[1.0, 0.0]]
      b = [[100.0, 0.0]]

      assert_in_delta Dtw.distance(a, b, metric: :cosine), 0.0, @eps
      assert Dtw.distance(a, b, metric: :euclidean) > 90.0
    end

    test "a zero vector is maximally dissimilar under cosine rather than a crash" do
      assert Dtw.distance([[0.0, 0.0]], [[1.0, 1.0]], metric: :cosine) == 1.0
    end

    test "an unknown metric falls back to euclidean rather than raising" do
      a = [[0.0, 0.0]]
      b = [[3.0, 4.0]]

      assert_in_delta Dtw.distance(a, b, metric: :not_a_metric), 5.0, @eps
    end

    test "a non-euclidean metric still finds a verbatim instance" do
      template = seq(20, 111)
      target = seq(30, 5) ++ template ++ seq(30, 6)

      assert [match] = Dtw.search(template, target, metric: :manhattan, threshold: @eps)
      assert match.start_frame == 30
    end

    test "cepstral mean normalisation still finds a verbatim instance, but not at zero" do
      # Worth pinning, because it surprises: CMN subtracts each sequence's *own*
      # mean, and a target holding the word plus 60 frames of something else has
      # a different mean than the template does. The verbatim copy therefore
      # stops being bit-identical after normalisation. It is still far and away
      # the best span — but a threshold tuned with :cmn off does not transfer.
      template = seq(20, 113)
      target = seq(30, 5) ++ template ++ seq(30, 6)

      assert [plain] = Dtw.search(template, target, threshold: @eps)
      assert [normalised] = Dtw.search(template, target, cmn: true, limit: 1)

      assert plain.distance == 0.0
      assert normalised.start_frame == 30
      assert normalised.end_frame == 49
      assert normalised.distance > 0.0
    end

    test "cepstral mean normalisation removes a constant channel offset" do
      # A whole recording shifted by a constant is what a different handset does
      # to cepstra. Without CMN that shift is the entire distance; with it, it
      # is nothing.
      seq = seq(30, 115)
      shifted = offset(seq, 0.5)

      assert Dtw.distance(seq, shifted) > 1.0
      assert_in_delta Dtw.distance(seq, shifted, cmn: true), 0.0, 1.0e-9
    end
  end

  describe "determinism" do
    test "the same inputs give byte-identical results every time" do
      template = seq(25, 121)
      gap = seq(30, 5)
      target = gap ++ template ++ gap ++ jitter(template, 0.05, 7) ++ gap

      first = Dtw.search(template, target, limit: :infinity, threshold: 1.0)

      assert Enum.all?(1..5, fn _ ->
               Dtw.search(template, target, limit: :infinity, threshold: 1.0) == first
             end)
    end

    test "ties break the same way every time" do
      # Two byte-identical instances score exactly equally; the order must still
      # be fixed, and it is by start frame.
      template = seq(20, 123)
      gap = seq(30, 5)
      target = gap ++ template ++ gap ++ template ++ gap

      matches = Dtw.search(template, target, threshold: @eps, limit: :infinity)

      assert Enum.map(matches, & &1.start_frame) == [30, 80]
    end
  end

  # ── Fixtures: deterministic synthetic features, no signal layer involved ───

  # A linear congruential generator, so every test's "audio" is reproducible
  # from its seed and nothing here depends on :rand's process state.
  defp seq(count, seed) do
    {frames, _state} =
      Enum.map_reduce(1..count, seed * 7919 + 1, fn _i, state ->
        vector(@dim, state, [])
      end)

    frames
  end

  defp vector(0, state, acc), do: {Enum.reverse(acc), state}

  defp vector(n, state, acc) do
    next = rem(state * 1_103_515_245 + 12_345, 2_147_483_648)
    vector(n - 1, next, [next / 2_147_483_648.0 * 2.0 - 1.0 | acc])
  end

  # Each frame repeated `factor` times: the same word said more slowly.
  defp stretch(seq, factor), do: Enum.flat_map(seq, &List.duplicate(&1, factor))

  # A constant added to every coefficient: local Euclidean distance becomes
  # exactly `amount * sqrt(dim)` for aligned frames, which makes the expected
  # normalised distance predictable to the digit.
  defp offset(seq, amount), do: Enum.map(seq, fn vec -> Enum.map(vec, &(&1 + amount)) end)

  # Deterministic pseudo-random noise of a bounded scale, for the cases where a
  # constant offset would be too tidy to be convincing.
  defp jitter(seq, scale, seed) do
    {frames, _state} =
      Enum.map_reduce(seq, seed * 104_729 + 3, fn vec, state ->
        {deltas, next} = vector(length(vec), state, [])
        {Enum.zip_with(vec, deltas, fn v, d -> v + d * scale end), next}
      end)

    frames
  end
end
