defmodule BusterClaw.Notifications.Cutup.FeaturesTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Cutup.Features
  alias BusterClaw.Notifications.Cutup.Mfcc
  alias BusterClaw.Notifications.Cutup.Signal
  alias BusterClaw.Notifications.SoundStudio

  # The studio's internal format. Fixtures are written at exactly this rate on
  # purpose: `SoundStudio.import_source/1` hands back an already-internal clip
  # untouched, so nothing in this file shells out to `afconvert`.
  @rate 22_050

  # A frame is 551 samples at this rate, so 1024 is the smallest radix-2 size
  # that holds one. Written out rather than derived — see SignalTest.
  @fft 1024

  setup do
    root = Path.join(System.tmp_dir!(), "bc_features_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp clip(samples) do
    data = for s <- samples, into: <<>>, do: <<s::little-signed-16>>
    %SoundStudio{sample_rate: @rate, channels: 1, bits: 16, data: data}
  end

  # A deterministic waveform with enough spectral variety that the coefficients
  # actually move frame to frame; a pure tone makes every frame identical and
  # would hide a serialisation bug that transposed them.
  defp tone(n, seed) do
    for i <- 0..(n - 1) do
      t = i / @rate

      value =
        0.5 * :math.sin(2.0 * :math.pi() * (180 + seed * 37) * t) +
          0.3 * :math.sin(2.0 * :math.pi() * (900 + seed * 111) * t) * :math.sin(9.0 * t) +
          0.1 * :math.sin(2.0 * :math.pi() * 3100 * t)

      round(value * 20_000)
    end
  end

  # 300 ms ≈ 28 analysis frames. Enough that CMN has something to average and
  # small enough that a full compute is tens of milliseconds.
  defp source!(name, samples) do
    File.mkdir_p!(SoundStudio.dir())
    c = clip(samples)
    :ok = SoundStudio.write(c, Path.join(SoundStudio.dir(), name))
    c
  end

  defp source_path(name), do: Path.join(SoundStudio.dir(), name)
  defp cache_path(name), do: Path.join(Features.dir(), name <> ".features.bin")

  defp cache_parts(name) do
    {:ok, body} = File.read(cache_path(name))
    ["BCFEAT1", rest] = :binary.split(body, "\n")
    [json, payload] = :binary.split(rest, "\n")
    {:ok, header} = Jason.decode(json)
    {header, payload}
  end

  defp rewrite_cache!(name, header, payload) do
    {:ok, json} = Jason.encode(header)
    File.write!(cache_path(name), "BCFEAT1\n" <> json <> "\n" <> payload)
  end

  defp zeroed(payload), do: :binary.copy(<<0>>, byte_size(payload))

  defp assert_recomputes(expected) do
    assert {:ok, seq} = Features.for_source("a.wav")
    assert_seq_equal(seq, expected)
  end

  defp assert_seq_equal(actual, expected) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {a, e} ->
      assert length(a) == length(e)

      Enum.zip(a, e)
      |> Enum.each(fn {x, y} -> assert x === y end)
    end)
  end

  # ---------------------------------------------------------------------------
  # compute/2 — the pure half
  # ---------------------------------------------------------------------------

  describe "compute/2" do
    test "one 13-coefficient vector per analysis frame" do
      c = clip(tone(6615, 1))
      expected = length(Signal.frames(c, fft_size: @fft))

      seq = Features.compute(c)

      assert length(seq) == expected
      assert expected > 20
      assert Enum.all?(seq, &(length(&1) == 13))
      assert Enum.all?(seq, fn vec -> Enum.all?(vec, &is_float/1) end)
    end

    test "CMN is applied over the WHOLE sequence, so every coefficient's mean is zero" do
      seq = Features.compute(clip(tone(6615, 2)))
      count = length(seq)

      sums =
        Enum.reduce(seq, List.duplicate(0.0, 13), fn vec, acc ->
          Enum.zip_with(vec, acc, &(&1 + &2))
        end)

      Enum.each(sums, fn total -> assert abs(total / count) < 1.0e-9 end)
    end

    test "CMN is NOT the per-frame normalisation it is easy to mistake it for" do
      # Frame means are not zero — only the sequence's per-coefficient means are.
      # A module that normalised each frame against its own mean would pass the
      # test above for c0 alone and be wrong about everything else.
      seq = Features.compute(clip(tone(6615, 2)))

      assert Enum.any?(seq, fn vec -> abs(Enum.sum(vec) / length(vec)) > 1.0e-6 end)
    end

    test "the sequence is Signal -> Mfcc with one shared fft_size, not each module's own default" do
      c = clip(tone(6615, 3))
      bank = Mfcc.new(fft_size: @fft, sample_rate: @rate, n_filters: 26, n_coeffs: 13)

      expected =
        c
        |> Signal.frames(fft_size: @fft, pre_emphasis: 0.97)
        |> Enum.map(&Mfcc.features(Signal.spectrum(&1), bank))
        |> Mfcc.cmn()

      assert_seq_equal(Features.compute(c), expected)
    end

    test "`cmn: false` leaves the un-normalised coefficients, and they differ" do
      c = clip(tone(6615, 4))

      normalised = Features.compute(c)
      raw = Features.compute(c, cmn: false)

      assert length(raw) == length(normalised)
      refute hd(raw) == hd(normalised)
    end

    test "a clip shorter than one 25 ms frame yields no features at all" do
      assert Features.compute(clip(tone(400, 5))) == []
    end

    test "`n_coeffs` changes the dimension the matcher sees" do
      seq = Features.compute(clip(tone(6615, 6)), n_coeffs: 8)
      assert Enum.all?(seq, &(length(&1) == 8))
    end
  end

  # ---------------------------------------------------------------------------
  # for_source/2 — round trip and cache hit
  # ---------------------------------------------------------------------------

  describe "for_source/2 round trip" do
    test "computes, saves, and loads back the same floats" do
      c = source!("a.wav", tone(6615, 7))

      refute Features.cached?("a.wav")
      assert {:ok, first} = Features.for_source("a.wav")
      assert Features.cached?("a.wav")
      assert File.regular?(cache_path("a.wav"))

      assert_seq_equal(first, Features.compute(c))

      # The point of float64: bit-identical on the way back, not merely close.
      assert {:ok, second} = Features.for_source("a.wav")
      assert_seq_equal(second, first)
    end

    test "an empty sequence round-trips as an empty sequence" do
      source!("tiny.wav", tone(400, 8))

      assert {:ok, []} = Features.for_source("tiny.wav")
      assert Features.cached?("tiny.wav")
      assert {:ok, []} = Features.for_source("tiny.wav")
    end

    test "the header records the parameters it was built for" do
      source!("a.wav", tone(6615, 9))
      {:ok, seq} = Features.for_source("a.wav")

      {header, payload} = cache_parts("a.wav")

      assert header["sample_rate"] == @rate
      assert header["fft_size"] == @fft
      assert header["hop_ms"] == Signal.hop_ms()
      assert header["frame_ms"] == Signal.frame_ms()
      assert header["n_filters"] == 26
      assert header["n_coeffs"] == 13
      assert header["pre_emphasis"] == 0.97
      assert header["cmn"] == true
      assert header["frames"] == length(seq)
      assert header["dims"] == 13
      assert header["bytes"] == File.stat!(source_path("a.wav")).size
      assert is_binary(header["sha256"])

      # float64, 13 per frame, nothing else in the payload.
      assert byte_size(payload) == length(seq) * 13 * 8
    end

    test "the second call is a cache HIT, proved by mutating the stored payload" do
      source!("a.wav", tone(6615, 10))
      assert {:ok, seq} = Features.for_source("a.wav")
      refute Enum.all?(hd(seq), &(&1 == 0.0))

      # Same header, same shape, same source identity — only the numbers differ.
      # A recompute would overwrite these; a hit returns them.
      {header, payload} = cache_parts("a.wav")
      rewrite_cache!("a.wav", header, :binary.copy(<<0>>, byte_size(payload)))

      assert {:ok, hit} = Features.for_source("a.wav")
      assert length(hit) == length(seq)
      assert Enum.all?(hit, fn vec -> vec == List.duplicate(0.0, 13) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Invalidation
  # ---------------------------------------------------------------------------

  describe "invalidation" do
    test "changing the audio recomputes" do
      source!("a.wav", tone(6615, 11))
      {:ok, before} = Features.for_source("a.wav")

      after_clip = source!("a.wav", tone(8000, 12))
      {:ok, now} = Features.for_source("a.wav")

      refute length(now) == length(before)
      assert_seq_equal(now, Features.compute(after_clip))
    end

    test "changing the audio recomputes even at the same size and the same mtime" do
      source!("a.wav", tone(6615, 13))
      {:ok, before} = Features.for_source("a.wav")

      path = source_path("a.wav")
      %File.Stat{size: size, mtime: mtime} = File.stat!(path, time: :posix)

      # A source re-saved at the same length inside the same second: stat cannot
      # tell, and only the digest catches it. This is the hole that makes a
      # size+mtime cache key quietly wrong.
      replaced = source!("a.wav", tone(6615, 14))
      File.touch!(path, mtime)

      assert %File.Stat{size: ^size, mtime: ^mtime} = File.stat!(path, time: :posix)

      {:ok, now} = Features.for_source("a.wav")

      refute now == before
      assert_seq_equal(now, Features.compute(replaced))
    end

    test "changing any analysis parameter recomputes" do
      c = source!("a.wav", tone(6615, 15))
      {:ok, base} = Features.for_source("a.wav")

      for {opts, label} <- [
            {[fft_size: 2048], "fft_size"},
            {[pre_emphasis: 0.5], "pre_emphasis"},
            {[n_filters: 20], "n_filters"},
            {[n_coeffs: 8], "n_coeffs"},
            {[cmn: false], "cmn"}
          ] do
        assert {:ok, seq} = Features.for_source("a.wav", opts), label
        refute seq == base, "#{label} did not invalidate the cache"
        assert_seq_equal(seq, Features.compute(c, opts))

        {header, _payload} = cache_parts("a.wav")
        assert header["frames"] == length(seq), label
      end

      # And the default parameters still get their own correct answer back.
      assert {:ok, again} = Features.for_source("a.wav")
      assert_seq_equal(again, base)
    end

    test "a stale frame geometry in the header recomputes" do
      source!("a.wav", tone(6615, 16))
      {:ok, expected} = Features.for_source("a.wav")

      {header, payload} = cache_parts("a.wav")
      rewrite_cache!("a.wav", Map.put(header, "hop_ms", 5.0), zeroed(payload))

      assert {:ok, seq} = Features.for_source("a.wav")
      assert_seq_equal(seq, expected)
    end
  end

  # ---------------------------------------------------------------------------
  # Corruption — recompute, never raise
  # ---------------------------------------------------------------------------

  describe "a corrupt cache recomputes rather than raising" do
    setup do
      c = source!("a.wav", tone(6615, 17))
      {:ok, expected} = Features.for_source("a.wav")
      {:ok, clip: c, expected: expected}
    end

    test "a truncated payload", %{expected: expected} do
      {header, payload} = cache_parts("a.wav")
      rewrite_cache!("a.wav", header, binary_part(payload, 0, byte_size(payload) - 16))
      assert_recomputes(expected)
    end

    test "a payload longer than the header claims", %{expected: expected} do
      {header, payload} = cache_parts("a.wav")
      rewrite_cache!("a.wav", header, payload <> <<0::float-64>>)
      assert_recomputes(expected)
    end

    test "a header that lies about its frame count", %{expected: expected} do
      {header, payload} = cache_parts("a.wav")
      rewrite_cache!("a.wav", Map.put(header, "frames", 4), payload)
      assert_recomputes(expected)
    end

    test "unparseable JSON in the header", %{expected: expected} do
      File.write!(cache_path("a.wav"), "BCFEAT1\n{not json\n" <> <<0::float-64>>)
      assert_recomputes(expected)
    end

    test "the wrong magic", %{expected: expected} do
      {:ok, body} = File.read(cache_path("a.wav"))
      File.write!(cache_path("a.wav"), "BCFEAT9" <> binary_part(body, 7, byte_size(body) - 7))
      assert_recomputes(expected)
    end

    test "an empty file", %{expected: expected} do
      File.write!(cache_path("a.wav"), "")
      assert_recomputes(expected)
    end

    test "arbitrary garbage", %{expected: expected} do
      File.write!(cache_path("a.wav"), :crypto.strong_rand_bytes(4096))
      assert_recomputes(expected)
    end

    test "a NaN bit pattern in the payload, which will not decode", %{expected: expected} do
      {header, payload} = cache_parts("a.wav")
      nan = <<0x7F, 0xF8, 0, 0, 0, 0, 0, 0>>
      rewrite_cache!("a.wav", header, nan <> binary_part(payload, 8, byte_size(payload) - 8))
      assert_recomputes(expected)
    end
  end

  # ---------------------------------------------------------------------------
  # The source gate
  # ---------------------------------------------------------------------------

  describe "the source gate" do
    @traversal [
      "../evil.wav",
      "a/b.wav",
      "..\\evil.wav",
      "/etc/passwd",
      "..",
      ".",
      "",
      "a\0.wav"
    ]

    test "traversal in a source name is refused by every entry point" do
      for name <- @traversal do
        assert {:error, reason} = Features.for_source(name), name
        assert reason in [:invalid_source, :unsafe_source], name

        assert {:error, gate} = Features.delete(name), name
        assert gate in [:invalid_source, :unsafe_source], name

        refute Features.cached?(name), name
      end
    end

    test "a name the audio sanitizer would rewrite is refused as unsafe" do
      assert {:error, :unsafe_source} = Features.for_source("we?ird.wav")
      assert {:error, :unsafe_source} = Features.delete("we?ird.wav")
    end

    test "a non-binary source is refused rather than raising" do
      assert {:error, :invalid_source} = Features.for_source(:a)
      assert {:error, :invalid_source} = Features.delete(nil)
      refute Features.cached?(123)
    end

    test "no traversal name can ever write outside the features directory" do
      for name <- @traversal, do: Features.for_source(name)
      assert Features.list() == []
    end

    test "a source the studio does not hold is not found" do
      assert {:error, :not_found} = Features.for_source("nope.wav")
    end

    test "a `.wav` that is not audio is refused rather than cached" do
      File.mkdir_p!(SoundStudio.dir())
      File.write!(source_path("prose.wav"), String.duplicate("not audio at all. ", 200))

      assert {:error, reason} = Features.for_source("prose.wav")
      assert reason in [:unsupported_format, :no_decoder]
      refute Features.cached?("prose.wav")
    end
  end

  # ---------------------------------------------------------------------------
  # list/0, delete/1
  # ---------------------------------------------------------------------------

  describe "list/0 and delete/1" do
    test "lists cached sources sorted, and nothing when the directory is absent" do
      assert Features.list() == []

      for name <- ["b.wav", "A.wav", "c.wav"], do: source!(name, tone(3000, 20))
      for name <- ["b.wav", "A.wav"], do: {:ok, _} = Features.for_source(name)

      assert Features.list() == ["A.wav", "b.wav"]
    end

    test "delete removes the cache and leaves the audio alone" do
      source!("a.wav", tone(3000, 21))
      {:ok, _} = Features.for_source("a.wav")

      assert :ok = Features.delete("a.wav")
      refute Features.cached?("a.wav")
      assert File.regular?(source_path("a.wav"))
      assert Features.list() == []

      assert {:error, :not_found} = Features.delete("a.wav")

      # And it comes back identical, because it is derived.
      assert {:ok, _seq} = Features.for_source("a.wav")
      assert Features.cached?("a.wav")
    end

    test "a stray non-cache file in the directory is ignored" do
      File.mkdir_p!(Features.dir())
      File.write!(Path.join(Features.dir(), "README.md"), "notes")
      assert Features.list() == []
    end
  end

  # ---------------------------------------------------------------------------
  # warm/2
  # ---------------------------------------------------------------------------

  describe "warm/2" do
    test "processes several sources and reports every one of them" do
      names = ["one.wav", "two.wav", "three.wav"]
      for {name, i} <- Enum.with_index(names), do: source!(name, tone(4410, 30 + i))

      result = Features.warm(names)

      assert Map.keys(result) |> Enum.sort() == Enum.sort(names)

      for name <- names do
        assert {:ok, count} = result[name]
        assert count > 5
        assert Features.cached?(name)
        assert {:ok, seq} = Features.for_source(name)
        assert length(seq) == count
      end

      assert Features.list() == Enum.sort(names)
    end

    test "a failing source does not take the others down, and is named in the result" do
      source!("good.wav", tone(4410, 40))

      result = Features.warm(["good.wav", "missing.wav", "../evil.wav"])

      assert {:ok, count} = result["good.wav"]
      assert count > 5
      assert result["missing.wav"] == {:error, :not_found}
      assert result["../evil.wav"] == {:error, :invalid_source}
    end

    test "warming twice is idempotent and does not disturb the stored features" do
      source!("a.wav", tone(4410, 41))

      first = Features.warm(["a.wav"])
      {:ok, seq} = Features.for_source("a.wav")
      second = Features.warm(["a.wav"])

      assert first == second
      assert {:ok, again} = Features.for_source("a.wav")
      assert_seq_equal(again, seq)
    end

    test "duplicates are collapsed, and options reach every task" do
      source!("a.wav", tone(4410, 42))

      result = Features.warm(["a.wav", "a.wav"], n_coeffs: 8, max_concurrency: 2)

      assert map_size(result) == 1
      {header, _payload} = cache_parts("a.wav")
      assert header["n_coeffs"] == 8
    end

    test "an empty list is an empty map, and a non-list is refused rather than raising" do
      assert Features.warm([]) == %{}
      assert Features.warm(:nope) == %{}
    end
  end
end
