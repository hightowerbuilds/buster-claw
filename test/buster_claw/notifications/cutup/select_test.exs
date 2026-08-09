defmodule BusterClaw.Notifications.Cutup.SelectTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Cutup.Select

  doctest BusterClaw.Notifications.Cutup.Select

  @eps 1.0e-9

  describe "the headline — a clearly-better take wins its slot" do
    test "every slot takes the confident, well-proportioned, quietly-bounded take" do
      # The bad take is listed FIRST in both slots, so "pick the head of the
      # list" is not a passing implementation.
      slots = [
        [
          take("junk.wav", "morning", 0, 60, confidence: 0.35),
          take("clean.wav", "morning", 0, 400, confidence: 0.95)
        ],
        [
          take("junk.wav", "to", 500, 1700, confidence: 0.40),
          take("clean.wav", "to", 1000, 1200, confidence: 0.95)
        ]
      ]

      assert {:ok, cuts} = Select.best(slots, opts())

      assert cuts == [
               %{source: "clean.wav", start_ms: 0.0, end_ms: 400.0},
               %{source: "clean.wav", start_ms: 1000.0, end_ms: 1200.0}
             ]
    end

    test "and it wins on all three of the terms that had data, not one of them" do
      slots = [
        [
          take("junk.wav", "morning", 0, 60, confidence: 0.35),
          take("clean.wav", "morning", 0, 400, confidence: 0.95)
        ],
        [
          take("junk.wav", "to", 500, 1700, confidence: 0.40),
          take("clean.wav", "to", 1000, 1200, confidence: 0.95)
        ]
      ]

      assert {:ok, plan} = Select.explain(slots, opts())
      [morning, to] = plan.targets

      # The winner is the population minimum on confidence, duration and
      # boundary, so every one of them normalises to exactly zero.
      assert morning.confidence == 0.0
      assert morning.duration == 0.0
      assert morning.boundary == 0.0
      assert to.confidence == 0.0
      assert to.duration == 0.0

      # Nothing had to be imputed: features and boundaries were injected for
      # every candidate. This is the assertion that stops the test passing
      # because the acoustic half quietly did not run.
      assert plan.imputed == %{boundary: 0, typicality: 0, join: 0}
    end
  end

  describe "the natural-run rule — adjacent in the source joins at zero" do
    # Slot 1 holds three takes of "to". Two of them (`b_far` and `b_run`) have
    # *byte-identical* features, so every target term scores them the same and
    # only the join can separate them — and `b_far` is listed first, so the
    # tie-break favours it. `b_run` wins solely because it is the frames that
    # follow `a` in the same recording.
    #
    # `b_near` exists to keep the join population honest: min-max would
    # otherwise map the cheapest real splice to zero, and there would be
    # nothing for the rule to beat.
    setup do
      features = %{
        # 20 frames of shape 1.0 (the "a" take) then 20 of shape 50.0 (`b_run`),
        # a deliberate discontinuity *inside one recording* so that the rule is
        # tested rather than a spectral coincidence.
        "run.wav" => frames(20, 0.0, 1.0) ++ frames(20, 0.0, 50.0),
        "near.wav" => frames(20, 0.0, 1.0),
        "far.wav" => frames(20, 0.0, 50.0)
      }

      slots = [
        [take("run.wav", "morning", 0, 200, confidence: 0.9)],
        [
          take("near.wav", "to", 0, 200, confidence: 0.0),
          take("far.wav", "to", 0, 200, confidence: 0.9),
          take("run.wav", "to", 200, 400, confidence: 0.9)
        ]
      ]

      %{features: features, slots: slots}
    end

    test "the adjacent take is chosen over an identically-featured stranger", ctx do
      assert {:ok, [_a, chosen]} = Select.best(ctx.slots, features: ctx.features)
      assert chosen == %{source: "run.wav", start_ms: 200.0, end_ms: 400.0}
    end

    test "and its join costs exactly zero on every term", ctx do
      assert {:ok, plan} = Select.explain(ctx.slots, features: ctx.features)
      assert plan.joins == [%{spectral: 0.0, level: 0.0, total: 0.0}]
      assert plan.join_total == 0.0
    end

    test "the seam it wins on is spectrally awful — the rule, not the spectrum", ctx do
      # Same lattice with the adjacency window closed. The winner's raw seam is
      # the *worst* in the lattice, so with the rule switched off it stops
      # winning: proof that the zero came from adjacency and not from the audio
      # happening to match.
      assert {:ok, [_a, chosen]} =
               Select.best(ctx.slots, features: ctx.features, adjacent_tolerance_frames: 0)

      refute chosen.source == "run.wav"
    end

    test "adjacent?/3 is about one recording and contiguous frames" do
      a = take("run.wav", "morning", 0, 200)
      following = take("run.wav", "to", 200, 400)
      elsewhere = take("other.wav", "to", 200, 400)
      distant = take("run.wav", "to", 5000, 5200)

      assert Select.adjacent?(a, following)
      refute Select.adjacent?(a, elsewhere)
      refute Select.adjacent?(a, distant)
      # Order matters: `a` does not follow the take that follows it.
      refute Select.adjacent?(following, a)
      # And the window is an option.
      refute Select.adjacent?(a, following, adjacent_tolerance_frames: 0)
    end
  end

  describe "the join cost genuinely decides — a greedy argmax would get this wrong" do
    # `run.wav` holds "hello to you" spoken straight through. The middle slot
    # also offers a take from another recording with a *better* confidence than
    # the one in the run, so a per-slot argmax over target costs picks it. It
    # then has to pay for two seams, and the whole-path cost says no.
    setup do
      features = %{
        "run.wav" => frames(80, 0.0, 1.0),
        "other.wav" => frames(20, 0.0, 9.0)
      }

      slots = [
        [take("run.wav", "hello", 0, 400, confidence: 0.75)],
        [
          take("other.wav", "to", 0, 200, confidence: 1.0),
          take("run.wav", "to", 400, 600, confidence: 0.5)
        ],
        [take("run.wav", "you", 600, 800, confidence: 0.75)]
      ]

      %{features: features, slots: slots}
    end

    test "the locally-best take loses because of what it costs to splice", ctx do
      assert {:ok, plan} = Select.explain(ctx.slots, features: ctx.features)
      [_hello, middle, _you] = plan.path

      assert middle.source == "run.wav"

      # It is genuinely the worse candidate on its own terms — this is what
      # makes it a Viterbi test and not a target-cost test.
      [_h, middle_target, _y] = plan.targets
      assert middle_target.confidence > 0.0
    end

    test "and turning the join weights off flips it back, so the join is what did it", ctx do
      assert {:ok, plan} =
               Select.explain(ctx.slots,
                 features: ctx.features,
                 weights: [spectral: 0.0, level: 0.0]
               )

      [_hello, middle, _you] = plan.path
      assert middle.source == "other.wav"
      assert plan.join_total == 0.0
    end

    test "the chosen path really is the cheapest, and its parts add up", ctx do
      assert {:ok, plan} = Select.explain(ctx.slots, features: ctx.features)

      assert length(plan.targets) == 3
      assert length(plan.joins) == 2
      assert_in_delta plan.total, plan.target_total + plan.join_total, @eps

      # The lattice is small enough to price by hand. Confidence is the only
      # target term with any spread (0.25 / 0.0 / 0.5 / 0.25 as costs), so it
      # normalises to 0.5 / 0.0 / 1.0 / 0.5; the joins are the run's, which are
      # free. Winning path: 0.5 + 1.0 + 0.5 = 2.0. The path through
      # `other.wav` is 0.5 + 0.0 + 0.5 plus two seams at the population maximum,
      # 2 x (spectral weight 2.0) = 5.0.
      assert_in_delta plan.target_total, 2.0, @eps
      assert plan.join_total == 0.0
      assert_in_delta plan.total, 2.0, @eps
    end

    test "a cost is only comparable inside one lattice, and that is worth knowing", ctx do
      # min-max normalises over the candidates actually present, so removing a
      # candidate re-scales every term. Two plans from two different lattices
      # cannot be ranked against each other, and a caller tempted to price an
      # alternative by forcing it will get a number that means something else.
      forced = List.replace_at(ctx.slots, 1, [Enum.at(Enum.at(ctx.slots, 1), 0)])

      assert {:ok, plan} = Select.explain(ctx.slots, features: ctx.features)
      assert {:ok, alternative} = Select.explain(forced, features: ctx.features)

      # Only one seam distance survives in the forced lattice, so the join term
      # has no spread left and reports zero — not because the splice got better.
      assert alternative.join_total == 0.0
      assert alternative.total <= plan.total
    end
  end

  describe "normalisation — the weights only mean something because of it" do
    # Three takes of one word, identical but for confidence and boundary. The
    # per-term arithmetic is small enough to do on paper:
    #
    #   confidence cost   1.0 -> 0.0     0.0 -> 1.0     0.9 -> 0.1
    #   boundary raw     10.0           0.0            1.0
    #
    # min-max maps each term onto 0..1 over the three, and the middle take wins
    # on 0.2 against 1.0 and 1.0. Raw, the boundary term is ten times the size
    # of the confidence term and simply is the answer.
    setup do
      slots = [
        [
          take("a.wav", "to", 0, 200, confidence: 1.0),
          take("a.wav", "to", 200, 400, confidence: 0.0),
          take("a.wav", "to", 400, 600, confidence: 0.9)
        ]
      ]

      boundary = %{{"a.wav", 0} => 10.0, {"a.wav", 20} => 0.0, {"a.wav", 40} => 1.0}

      %{slots: slots, boundary: boundary}
    end

    test "inflating one term's raw scale 100x does not change the answer", ctx do
      inflated = Map.new(ctx.boundary, fn {key, value} -> {key, value * 100.0} end)

      assert Select.best(ctx.slots, boundary: ctx.boundary) ==
               Select.best(ctx.slots, boundary: inflated)

      assert {:ok, [chosen]} = Select.best(ctx.slots, boundary: ctx.boundary)
      assert chosen.start_ms == 400.0
    end

    test "shrinking it 100x does not either", ctx do
      shrunk = Map.new(ctx.boundary, fn {key, value} -> {key, value / 100.0} end)

      assert Select.best(ctx.slots, boundary: ctx.boundary) ==
               Select.best(ctx.slots, boundary: shrunk)
    end

    test "un-normalised, the units alone decide — which is the trap", ctx do
      shrunk = Map.new(ctx.boundary, fn {key, value} -> {key, value / 100.0} end)

      assert {:ok, [big]} = Select.best(ctx.slots, boundary: ctx.boundary, normalize: :none)
      assert {:ok, [small]} = Select.best(ctx.slots, boundary: shrunk, normalize: :none)

      # Same candidates, same weights, same ranking of every underlying
      # measurement — and a different sentence, purely because one term was
      # quoted in different units.
      refute big == small
    end

    test "scaling the whole feature space 100x does not change the answer" do
      features = %{
        "run.wav" => frames(80, 0.0, 1.0),
        "other.wav" => frames(20, 0.0, 9.0)
      }

      inflated = Map.new(features, fn {src, seq} -> {src, scale(seq, 100.0)} end)

      slots = [
        [take("run.wav", "hello", 0, 400, confidence: 0.75)],
        [
          take("other.wav", "to", 0, 200, confidence: 1.0),
          take("run.wav", "to", 400, 600, confidence: 0.5)
        ],
        [take("run.wav", "you", 600, 800, confidence: 0.75)]
      ]

      assert Select.best(slots, features: features) == Select.best(slots, features: inflated)
    end

    test "a term with no spread at all contributes nothing rather than something arbitrary" do
      # Every candidate has the same confidence, so the term carries no
      # information about which to pick and must be silent.
      slots = [
        [
          take("a.wav", "to", 0, 200, confidence: 0.5),
          take("b.wav", "to", 0, 200, confidence: 0.5)
        ]
      ]

      assert {:ok, plan} = Select.explain(slots)
      assert Enum.all?(plan.targets, &(&1.confidence == 0.0))
      assert plan.total == 0.0
    end
  end

  describe "typicality — the take that sits away from its siblings loses" do
    test "an outlier take of a word is not chosen" do
      features = %{
        "a.wav" => frames(20, 0.0, 1.0),
        "b.wav" => frames(20, 0.0, 1.05),
        "odd.wav" => frames(20, 0.0, 9.0)
      }

      slots = [
        [
          take("a.wav", "to", 0, 200, confidence: 0.8),
          take("b.wav", "to", 0, 200, confidence: 0.8),
          take("odd.wav", "to", 0, 200, confidence: 0.8)
        ]
      ]

      assert {:ok, [chosen]} = Select.best(slots, features: features)
      refute chosen.source == "odd.wav"
      assert chosen.source == "b.wav"
    end

    test "with no features injected the term is imputed, and says so" do
      slots = [
        [take("a.wav", "to", 0, 200), take("b.wav", "to", 0, 200)],
        [take("a.wav", "you", 400, 600)]
      ]

      assert {:ok, plan} = Select.explain(slots)
      assert plan.imputed.typicality == 3
      assert plan.imputed.boundary == 3
      assert plan.imputed.join == 2
      # Nothing was measurable, so nothing was pretended: every term is zero.
      assert plan.total == 0.0
    end
  end

  describe "degenerate lattices" do
    test "one slot, one candidate, that candidate" do
      slots = [[take("a.wav", "morning", 100, 500)]]

      assert Select.best(slots) == {:ok, [%{source: "a.wav", start_ms: 100.0, end_ms: 500.0}]}
    end

    test "explain/2 reports when the search had nothing to decide" do
      slots = [[take("a.wav", "morning", 0, 400)], [take("a.wav", "to", 400, 600)]]

      assert {:ok, plan} = Select.explain(slots)
      # One candidate per slot: the corpus, not the algorithm, is the constraint.
      assert plan.slots == 2
      assert plan.candidates == 2
      assert plan.total == 0.0
    end

    test "an empty slot is a named error, because no path exists through it" do
      assert Select.best([[]]) == {:error, :empty_slot}
      assert Select.best([[take("a.wav", "to", 0, 200)], []]) == {:error, :empty_slot}
      assert Select.best([[], [take("a.wav", "to", 0, 200)]]) == {:error, :empty_slot}
    end

    test "no slots at all is a different named error" do
      assert Select.best([]) == {:error, :no_slots}
      assert Select.best("not a lattice") == {:error, :no_slots}
      assert Select.best([:not_a_slot]) == {:error, :no_slots}
    end

    test "a malformed candidate is named rather than crashed through" do
      assert Select.best([[%{source: "a.wav"}]]) == {:error, :bad_candidate}

      assert Select.best([[%{take("a.wav", "to", 0, 200) | frame1: 0, frame0: 5}]]) ==
               {:error, :bad_candidate}

      assert Select.best([[%{take("a.wav", "to", 0, 200) | source: :atom}]]) ==
               {:error, :bad_candidate}
    end
  end

  describe "feature validation — named errors, never a raise" do
    test "ragged vectors inside one source" do
      slots = [[take("a.wav", "to", 0, 200)]]
      features = %{"a.wav" => [[1.0, 2.0, 3.0], [1.0, 2.0]]}

      assert Select.best(slots, features: features) == {:error, :ragged_features}
    end

    test "vectors of different dimensions between two sources" do
      slots = [[take("a.wav", "to", 0, 200)], [take("b.wav", "you", 0, 200)]]
      features = %{"a.wav" => [[1.0, 2.0, 3.0]], "b.wav" => [[1.0, 2.0]]}

      assert Select.best(slots, features: features) == {:error, :ragged_features}
    end

    test "something that is not a feature sequence at all" do
      slots = [[take("a.wav", "to", 0, 200)]]

      assert Select.best(slots, features: %{"a.wav" => [[1.0], :nope]}) == {:error, :bad_features}
      assert Select.best(slots, features: %{"a.wav" => :nope}) == {:error, :bad_features}
      assert Select.best(slots, features: "nope") == {:error, :bad_features}
      assert Select.best(slots, features: fn _source -> :nope end) == {:error, :bad_features}
    end

    test "a source with no features is not an error — it costs the acoustic terms" do
      slots = [[take("a.wav", "to", 0, 200)], [take("b.wav", "you", 0, 200)]]
      features = %{"a.wav" => frames(20, 0.0, 1.0)}

      assert {:ok, [_a, _b]} = Select.best(slots, features: features)
      assert {:ok, plan} = Select.explain(slots, features: features)
      assert plan.imputed.join == 1
      assert plan.imputed.typicality == 2
    end

    test "a candidate whose frames fall outside its feature sequence degrades rather than raises" do
      slots = [[take("a.wav", "to", 5000, 5200)]]
      features = %{"a.wav" => frames(20, 0.0, 1.0)}

      assert {:ok, [cut]} = Select.best(slots, features: features)
      assert cut.start_ms == 5000.0
    end
  end

  describe "weights" do
    test "a negative weight is refused — it would turn a cost into a reward" do
      slots = [[take("a.wav", "to", 0, 200)]]

      assert Select.best(slots, weights: [confidence: -1.0]) == {:error, :bad_weights}
      assert Select.best(slots, weights: %{spectral: -0.001}) == {:error, :bad_weights}
      assert Select.best(slots, weights: [confidence: :loud]) == {:error, :bad_weights}
      assert Select.best(slots, weights: :loud) == {:error, :bad_weights}
    end

    test "the defaults are reported, and an override lands" do
      slots = [[take("a.wav", "to", 0, 200)]]

      assert {:ok, plan} = Select.explain(slots)

      assert plan.weights == %{
               confidence: 1.0,
               duration: 1.0,
               boundary: 1.0,
               typicality: 1.0,
               spectral: 2.0,
               level: 1.0
             }

      assert {:ok, tuned} = Select.explain(slots, weights: [confidence: 3.0])
      assert tuned.weights.confidence == 3.0
      assert tuned.weights.duration == 1.0
    end

    test "zeroing a weight silences exactly that term" do
      slots = [
        [
          take("a.wav", "to", 0, 200, confidence: 1.0),
          take("b.wav", "to", 0, 200, confidence: 0.0)
        ]
      ]

      assert {:ok, [chosen]} = Select.best(slots)
      assert chosen.source == "a.wav"

      # With confidence silenced the two are indistinguishable and the
      # tie-break, not the cost, decides.
      assert {:ok, [tied]} = Select.best(slots, weights: [confidence: 0.0])
      assert tied.source == "a.wav"

      assert {:ok, [reversed]} =
               Select.best([Enum.reverse(hd(slots))], weights: [confidence: 0.0])

      assert reversed.source == "b.wav"
    end
  end

  describe "determinism and the tie-break" do
    test "a genuine tie goes to the candidate the caller listed first" do
      a = take("a.wav", "to", 0, 200, confidence: 0.8)
      b = take("b.wav", "to", 0, 200, confidence: 0.8)

      assert {:ok, [%{source: "a.wav"}]} = Select.best([[a, b]])
      assert {:ok, [%{source: "b.wav"}]} = Select.best([[b, a]])
    end

    test "the same lattice gives the same answer every time" do
      features = %{
        "run.wav" => frames(80, 0.0, 1.0),
        "other.wav" => frames(20, 0.0, 9.0),
        "third.wav" => frames(20, 0.5, 3.0)
      }

      slots = [
        [
          take("run.wav", "hello", 0, 400, confidence: 0.75),
          take("third.wav", "hello", 0, 200, confidence: 0.9)
        ],
        [
          take("other.wav", "to", 0, 200, confidence: 1.0),
          take("run.wav", "to", 400, 600, confidence: 0.5),
          take("third.wav", "to", 0, 200, confidence: 0.7)
        ],
        [
          take("run.wav", "you", 600, 800, confidence: 0.75),
          take("other.wav", "you", 0, 200, confidence: 0.8)
        ]
      ]

      first = Select.best(slots, features: features)
      assert Enum.all?(1..20, fn _ -> Select.best(slots, features: features) == first end)
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures. No audio, no files: candidates are literals and feature sequences
  # are constants, so every number in every assertion above can be worked out on
  # paper.
  # ---------------------------------------------------------------------------

  # The 10 ms hop is the clock, so a candidate's frames follow from its
  # milliseconds. `frame1` is inclusive, matching `t:Types.match/0`.
  defp take(source, word, start_ms, end_ms, opts \\ []) do
    frame0 = trunc(start_ms / 10)

    %{
      source: source,
      word: %{
        word: word,
        text: word,
        start_ms: start_ms * 1.0,
        end_ms: end_ms * 1.0,
        confidence: Keyword.get(opts, :confidence, 0.9)
      },
      frame0: frame0,
      frame1: max(trunc(end_ms / 10) - 1, frame0)
    }
  end

  # Coefficient 0 is the level term's input and everything above it is the
  # spectral term's, so the two are separately controllable here.
  defp frames(count, level, shape), do: List.duplicate([level, shape, shape, shape], count)

  defp scale(seq, factor), do: Enum.map(seq, fn vec -> Enum.map(vec, &(&1 * factor)) end)

  defp opts do
    [
      features: %{
        "clean.wav" => frames(200, 0.0, 1.0),
        "junk.wav" => frames(200, 0.0, 1.0)
      },
      boundary: %{
        {"clean.wav", 0} => 0.01,
        {"clean.wav", 100} => 0.02,
        {"junk.wav", 0} => 0.9,
        {"junk.wav", 50} => 0.8
      }
    ]
  end
end
