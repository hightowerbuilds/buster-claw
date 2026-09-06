defmodule BusterClaw.Voice.CalibrationTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Voice.Calibration

  describe "what drives the estimate" do
    test "longer text costs more" do
      short = Calibration.estimate_seconds("Hi.", 6.0, 10)
      long = Calibration.estimate_seconds(String.duplicate("Hi. ", 20), 6.0, 10)

      assert long > short * 2
    end

    test "a longer reference clip costs more, because cloning pays it every step" do
      six = Calibration.estimate_seconds("Take me to the river!", 6.0, 10)
      thirteen = Calibration.estimate_seconds("Take me to the river!", 13.3, 10)

      assert thirteen > six
    end

    test "no reference at all is the cheap path" do
      design = Calibration.estimate_seconds("Take me to the river!", 0.0, 10)
      clone = Calibration.estimate_seconds("Take me to the river!", 6.0, 10)

      assert design < clone
    end

    test "steps scale the generating half, and not the floor under it" do
      ten = Calibration.estimate_seconds("Take me to the river!", 6.0, 10)
      four = Calibration.estimate_seconds("Take me to the river!", 6.0, 4)

      # Fewer steps is cheaper, but NOT proportionally: the warm-up runs its ten
      # iterations whatever is asked for. Measured 585 s -> 380 s, which is 65%
      # and not the 40% a whole-expression scale would predict. That wrong
      # version shipped in the first draft of this module.
      assert four < ten
      assert four > ten * 0.5
    end
  end

  describe "the seed, against what was actually measured on 09-06" do
    # Both runs rendered "Take me to the river!" on the operator's i9. The
    # 6-second reference finished in 585 s; the 13.3-second one was killed at
    # 628 s still running. A seed that does not reproduce its own measurements
    # is a seed nobody should trust.
    # 585 s was measured while a denoiser the app never calls was still being
    # loaded; the seed describes renders as they run NOW, without it, so the
    # 4-step run — the first measured under the current flags — is the one the
    # seed must reproduce.
    test "predicts the 4-step run measured under the current flags" do
      assert_in_delta Calibration.estimate_seconds("Take me to the river!", 6.0, 4), 380, 25
    end

    test "the fixed floor is most of a short render, and no setting removes it" do
      floor = Calibration.estimate_seconds("", 6.0, 1)

      assert floor > 250
      assert Calibration.estimate_seconds("Take me to the river!", 6.0, 1) > floor
    end

    test "predicts the run that did not finish as longer than where it was killed" do
      assert Calibration.estimate_seconds("Take me to the river!", 13.28, 10) > 628
    end
  end

  describe "the deadline" do
    test "leaves room above the estimate, so a busy machine does not lose the work" do
      text = "Take me to the river!"
      estimate_ms = Calibration.estimate_seconds(text, 6.0, 10) * 1000

      assert Calibration.deadline_ms(text, 6.0, 10) > estimate_ms * 1.5
    end

    test "never drops below a floor, whatever the calibration says" do
      assert Calibration.deadline_ms("", 0.0, 1) >= 300_000
    end

    test "is capped, so one job cannot hold the single queue for an afternoon" do
      huge = String.duplicate("a very long line indeed. ", 500)

      assert Calibration.deadline_ms(huge, 13.0, 30) <= 5_400_000
    end

    test "an explicit configuration wins outright" do
      Application.put_env(:buster_claw, :voice_render_timeout_ms, 42_000)
      on_exit(fn -> Application.delete_env(:buster_claw, :voice_render_timeout_ms) end)

      assert Calibration.deadline_ms("anything", 6.0, 10) == 42_000
    end
  end

  describe "learning from a finished render" do
    test "a machine twice as slow raises the estimate, without overshooting to it" do
      text = "Take me to the river!"
      before = Calibration.estimate_seconds(text, 6.0, 10)

      Calibration.record(text, 6.0, 10, before * 2)
      after_once = Calibration.estimate_seconds(text, 6.0, 10)

      assert after_once > before
      assert after_once < before * 2
    end

    test "repeated evidence converges on it" do
      text = "Take me to the river!"
      target = Calibration.estimate_seconds(text, 6.0, 10) * 2

      for _ <- 1..12, do: Calibration.record(text, 6.0, 10, target)

      assert_in_delta Calibration.estimate_seconds(text, 6.0, 10), target, target * 0.05
    end

    test "a timeout teaches nothing, because it only bounds the cost" do
      text = "Take me to the river!"
      before = Calibration.estimate_seconds(text, 6.0, 10)

      Calibration.record(text, 6.0, 10, 0)
      Calibration.record(text, 6.0, 10, nil)

      assert Calibration.estimate_seconds(text, 6.0, 10) == before
    end
  end

  # A machine where this is fast. Everything on the operator's i9 is minutes —
  # the fixed floor alone is 267 s — so a test about short waits has to say
  # which machine it is on, and the only honest way to say that is to teach the
  # calibration a fast one.
  defp calibrate_fast do
    for _ <- 1..25, do: Calibration.record("Take me to the river!", 6.0, 10, 4.0)
  end

  describe "the phrase shown to a person" do
    test "says minutes when it means minutes" do
      assert Calibration.phrase("Take me to the river!", 6.0, 10) =~ ~r/about \d+ minutes/
    end

    test "says under a minute when the machine is quick enough to mean it" do
      calibrate_fast()

      assert Calibration.phrase("Hi.", 0.0, 1) =~ ~r/under a minute|minute or two/
    end

    test "says so when the answer is not minutes at all" do
      assert Calibration.phrase(String.duplicate("x", 4_000), 13.0, 30) == "over an hour"
    end
  end

  describe "slow?" do
    test "a quick job on a quick machine needs no warning" do
      calibrate_fast()

      refute Calibration.slow?("Hi", 0.0, 1)
    end

    test "every render on the machine this was measured on is slow, floor included" do
      # Not a quirk of a long line: the fixed cost alone is over four minutes
      # here, so there is no line short enough to escape the warning. That is
      # the finding, not a threshold that needs loosening.
      assert Calibration.slow?("Hi", 0.0, 1)
      assert Calibration.slow?("Take me to the river!", 6.0, 10)
    end
  end
end
