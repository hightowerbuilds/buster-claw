defmodule BusterClaw.Notifications.SoundGenTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.SoundGen

  # SOUND_ROADMAP Part II — every routing key except "default" gets a bundled
  # chime. If a key is added there without a spec here, this list is the test
  # that says so.
  @expected ~w(alarm blocked boot chat confirm email manual order reminder
               security shift sms terminal timer voicemail web)

  test "the set covers every routing key that needs a bundled default" do
    assert SoundGen.keys() == @expected
  end

  test "rendering is deterministic — same input, byte-identical output" do
    for key <- SoundGen.keys() do
      assert SoundGen.render(key) == SoundGen.render(key),
             "#{key} rendered differently across two calls"
    end
  end

  test "every chime is a structurally valid PCM16 mono WAV" do
    for key <- SoundGen.keys() do
      binary = SoundGen.render(key)

      assert <<"RIFF", riff_len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
               channels::little-16, rate::little-32, byte_rate::little-32, block_align::little-16,
               bits::little-16, "data", data_len::little-32, data::binary>> = binary

      assert channels == 1, "#{key}: not mono"
      assert rate == 22_050
      assert bits == 16
      assert block_align == 2
      assert byte_rate == rate * block_align
      # The two declared lengths must agree with the actual bytes — a WAV with a
      # lying header plays as a truncated pop or not at all.
      assert byte_size(data) == data_len, "#{key}: data chunk length lies"
      assert riff_len == 36 + data_len, "#{key}: RIFF length lies"
      assert rem(data_len, 2) == 0, "#{key}: odd byte count cannot be PCM16"
    end
  end

  test "no chime is silence, and none clips" do
    for key <- SoundGen.keys() do
      <<_header::binary-size(44), data::binary>> = SoundGen.render(key)

      samples = for <<s::little-signed-16 <- data>>, do: s
      peak = samples |> Enum.map(&abs/1) |> Enum.max()

      assert peak > 3_000, "#{key} is (near) silence — peak #{peak}"
      assert peak < 32_767, "#{key} clips at full scale"
    end
  end

  test "every chime starts and ends at (near) zero — the anti-click contract" do
    for key <- SoundGen.keys() do
      <<_header::binary-size(44), data::binary>> = SoundGen.render(key)

      <<first::little-signed-16, _::binary>> = data
      <<last::little-signed-16>> = binary_part(data, byte_size(data) - 2, 2)

      assert abs(first) < 500, "#{key} starts hot (#{first}) — will click"
      assert abs(last) < 500, "#{key} ends hot (#{last}) — will click"
    end
  end

  test "durations stay in chime territory" do
    for key <- SoundGen.keys() do
      <<_::binary-size(40), data_len::little-32, _::binary>> = SoundGen.render(key)
      ms = data_len / 2 / 22_050 * 1000

      # The two deliberate long ones are the repeaters; everything else must
      # stay short enough to never compete with music or speech.
      cap = if key in ["alarm", "security"], do: 1_600, else: 900
      assert ms <= cap, "#{key} runs #{round(ms)}ms — past its #{cap}ms cap"
      assert ms >= 100, "#{key} is too short to register"
    end
  end

  test "write_all writes <key>.wav for the whole set, deterministically" do
    dir = Path.join(System.tmp_dir!(), "bc_soundgen_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    names = SoundGen.write_all(dir)

    assert names == Enum.map(@expected, &(&1 <> ".wav"))
    first_pass = for n <- names, into: %{}, do: {n, File.read!(Path.join(dir, n))}

    # Second run over the same dir: byte-identical, nothing new, nothing lost.
    assert SoundGen.write_all(dir) == names

    for n <- names do
      assert File.read!(Path.join(dir, n)) == first_pass[n], "#{n} changed across runs"
    end
  end
end
