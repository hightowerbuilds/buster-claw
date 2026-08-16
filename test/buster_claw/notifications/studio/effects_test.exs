defmodule BusterClaw.Notifications.Studio.EffectsTest do
  @moduledoc """
  The Studio's effect chain — the DSP and the contract around it.

  Pure: no workspace, no database, no files. That is a property of the module
  under test rather than of this file, and it is worth keeping — an effect that
  needed the disk could not be applied inside a render loop.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.Studio.Effects

  # A clip whose samples are distinguishable at every position, so reversal and
  # resampling are visible rather than plausible.
  defp clip(samples) do
    data = Enum.reduce(samples, <<>>, fn s, acc -> acc <> <<s::little-signed-16>> end)
    %SoundStudio{sample_rate: 22_050, channels: 1, bits: 16, data: data}
  end

  defp samples(%SoundStudio{data: data}), do: for(<<s::little-signed-16 <- data>>, do: s)

  defp effect(type, params \\ %{}) do
    {:ok, built} = Effects.build(type)
    Enum.reduce(params, built, fn {k, v}, acc -> Effects.put_param(acc, k, v) end)
  end

  describe "the catalog" do
    test "every entry can be built, and builds with its declared defaults" do
      for %{type: type, params: declared} <- Effects.catalog() do
        assert {:ok, %{type: ^type, params: params}} = Effects.build(type)

        for {key, {_min, _max, default}} <- declared do
          assert params[key] == default, "#{type}.#{key} did not build with its default"
        end
      end
    end

    test "every entry can be APPLIED — a catalog entry with no clause is a dead control" do
      subject = clip([100, -200, 300, -400, 500])

      for %{type: type} <- Effects.catalog() do
        result = Effects.apply_one(subject, effect(type))

        assert %SoundStudio{} = result, "#{type} did not return a clip"
        assert result.sample_rate == subject.sample_rate, "#{type} changed the sample rate"
        assert result.channels == subject.channels, "#{type} changed the channel count"
        assert result.bits == subject.bits, "#{type} changed the bit depth"
      end
    end

    test "an unknown type cannot be built, so it never reaches a mix" do
      assert :error = Effects.build("teleport")
      refute Effects.known?("teleport")
    end
  end

  describe "reverse" do
    test "is exact — reversing twice is the original, byte for byte" do
      subject = clip([1, 2, 3, 4, 5, -6, -7])
      once = Effects.apply_one(subject, effect("reverse"))

      assert samples(once) == [-7, -6, 5, 4, 3, 2, 1]
      assert Effects.apply_one(once, effect("reverse")).data == subject.data
    end
  end

  describe "gain" do
    test "scales, and SATURATES rather than wrapping at the rail" do
      subject = clip([1000, -1000, 30_000, -30_000])
      loud = Effects.apply_one(subject, effect("gain", %{"amount" => 2.0}))

      # 30_000 * 2 would wrap to a large NEGATIVE sample — the harshest possible
      # click, at exactly the loudest moment of the clip.
      assert samples(loud) == [2000, -2000, 32_767, -32_768]
    end

    test "unity gain leaves the audio alone" do
      subject = clip([1, -2, 3])
      assert Effects.apply_one(subject, effect("gain", %{"amount" => 1.0})).data == subject.data
    end
  end

  describe "speed" do
    test "halves the length at 2x, and doubles it at 0.5x" do
      subject = clip(Enum.to_list(1..100))

      faster = Effects.apply_one(subject, effect("speed", %{"rate" => 2.0}))
      slower = Effects.apply_one(subject, effect("speed", %{"rate" => 0.5}))

      assert length(samples(faster)) == 50
      assert length(samples(slower)) == 200
    end

    test "unity rate is a no-op" do
      subject = clip([10, 20, 30, 40])
      assert Effects.apply_one(subject, effect("speed", %{"rate" => 1.0})).data == subject.data
    end

    test "a rate outside the declared range is clamped, not obeyed" do
      subject = clip(Enum.to_list(1..100))

      # 100.0 is far past the catalog's 4.0 ceiling. Clamping means the result is
      # 25 samples, not 1 — and crucially, not a crash.
      result = Effects.apply_one(subject, effect("speed", %{"rate" => 100.0}))
      assert length(samples(result)) == 25
    end
  end

  describe "reverb" do
    test "adds a tail — the clip gets LONGER, which the timeline does not chase" do
      subject = clip(List.duplicate(8000, 2205))
      wet = Effects.apply_one(subject, effect("reverb"))

      assert length(samples(wet)) > length(samples(subject))
    end

    test "a fully dry mix returns the clip untouched" do
      subject = clip([100, 200, 300])
      assert Effects.apply_one(subject, effect("reverb", %{"mix" => 0.0})).data == subject.data
    end

    test "never exceeds the rail, however much feedback it is given" do
      subject = clip(List.duplicate(32_000, 1000))
      wet = Effects.apply_one(subject, effect("reverb", %{"size" => 1.0, "mix" => 1.0}))

      assert Enum.all?(samples(wet), &(&1 >= -32_768 and &1 <= 32_767))
    end
  end

  describe "the chain" do
    test "applies in order, and order is audible" do
      subject = clip([1, 2, 3, 4])

      # gain-then-reverse and reverse-then-gain agree here (both are pointwise),
      # but reverse-then-SPEED and speed-then-reverse need not, and the chain
      # must not reorder either way.
      a = Effects.apply_chain(subject, [effect("reverse"), effect("gain", %{"amount" => 2.0})])
      b = Effects.apply_chain(subject, [effect("gain", %{"amount" => 2.0}), effect("reverse")])

      assert samples(a) == [8, 6, 4, 2]
      assert samples(a) == samples(b)
    end

    test "an empty or absent chain is the identity" do
      subject = clip([1, 2, 3])

      assert Effects.apply_chain(subject, []).data == subject.data
      assert Effects.apply_chain(subject, nil).data == subject.data
    end

    test "an unknown effect in a chain is SKIPPED, so a hand-edited mix still renders" do
      subject = clip([1, 2, 3])
      chain = [%{type: "teleport", params: %{}}, effect("reverse")]

      assert samples(Effects.apply_chain(subject, chain)) == [3, 2, 1]
    end

    test "garbage in the chain does not raise" do
      subject = clip([1, 2, 3])

      for junk <- [%{}, %{type: nil}, "nonsense", 7, nil] do
        assert %SoundStudio{} = Effects.apply_chain(subject, [junk])
      end
    end
  end

  describe "parameters" do
    test "are clamped to the declared range on the way in" do
      loud = effect("gain", %{"amount" => 999.0})
      quiet = effect("gain", %{"amount" => -5.0})

      assert loud.params["amount"] == 4.0
      assert quiet.params["amount"] == 0.0
    end

    test "a string from a form is accepted, because that is what a range input sends" do
      assert effect("gain", %{"amount" => "2.5"}).params["amount"] == 2.5
    end

    test "an unknown parameter or unusable value leaves the effect alone" do
      built = effect("gain")

      assert Effects.put_param(built, "wobble", 1.0) == built
      assert Effects.put_param(built, "amount", "banana") == built
      assert Effects.put_param(built, "amount", nil) == built
    end
  end
end
