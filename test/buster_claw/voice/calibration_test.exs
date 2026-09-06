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

    test "steps scale it linearly" do
      ten = Calibration.estimate_seconds("Take me to the river!", 6.0, 10)
      four = Calibration.estimate_seconds("Take me to the river!", 6.0, 4)

      assert_in_delta four, ten * 0.4, 1.0
    end
  end

  describe "the seed, against what was actually measured on 09-06" do
    # Both runs rendered "Take me to the river!" on the operator's i9. The
    # 6-second reference finished in 585 s; the 13.3-second one was killed at
    # 628 s still running. A seed that does not reproduce its own measurements
    # is a seed nobody should trust.
    test "predicts the run that finished" do
      assert_in_delta Calibration.estimate_seconds("Take me to the river!", 6.0, 10), 585, 30
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

  describe "the phrase shown to a person" do
    test "is coarse on purpose — an estimate that reads as precise reads as a promise" do
      assert Calibration.phrase("Hi.", 0.0, 1) =~ ~r/under a minute|minute or two/
      assert Calibration.phrase("Take me to the river!", 6.0, 10) =~ ~r/about \d+ minutes/
    end

    test "says so when the answer is not minutes at all" do
      assert Calibration.phrase(String.duplicate("x", 4_000), 13.0, 30) == "over an hour"
    end
  end

  describe "slow?" do
    test "a quick job needs no warning" do
      refute Calibration.slow?("Hi", 0.0, 1)
    end

    test "a clone on this machine does" do
      assert Calibration.slow?("Take me to the river!", 6.0, 10)
    end
  end
end
