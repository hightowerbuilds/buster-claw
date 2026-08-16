defmodule BusterClaw.Notifications.Capture.TakeTest do
  @moduledoc """
  `Capture.Take` — the server half of the in-app recorder (`STUDIO_ROADMAP` V.7).

  DataCase because `store/3` indexes into the active bank, which is a `Settings`
  read. The decode half needs no database and is exercised through the same
  setup only for convenience.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Capture.Take
  alias BusterClaw.Notifications.Cutup.Bank
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.SoundStudio

  @rate 48_000

  setup do
    root = Path.join(System.tmp_dir!(), "bc_take_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A short tone at a given amplitude, as the browser would send it: base64
  # Float32 little-endian.
  defp pcm(amplitude, samples \\ 480) do
    0..(samples - 1)
    |> Enum.map(fn i -> amplitude * :math.sin(2 * :math.pi() * 440 * i / @rate) end)
    |> Enum.reduce(<<>>, fn f, acc -> acc <> <<f::little-float-32>> end)
    |> Base.encode64()
  end

  describe "decode" do
    test "float PCM becomes a 16-bit mono clip at the rate the device ran at" do
      assert {:ok, take} = Take.decode(pcm(0.5), @rate)

      assert %SoundStudio{sample_rate: @rate, channels: 1, bits: 16} = take.clip
      assert SoundStudio.sample_count(take.clip) == 480
      assert_in_delta take.duration_ms, 10.0, 0.001
    end

    test "nothing is resampled — the native rate is archived" do
      assert {:ok, %{sample_rate: 44_100, clip: %{sample_rate: 44_100}}} =
               Take.decode(pcm(0.5), 44_100)
    end

    test "peak is measured on the floats, before int16 conversion can clamp it" do
      assert {:ok, %{peak: peak, clipped?: false}} = Take.decode(pcm(0.5), @rate)
      assert_in_delta peak, 0.5, 0.01
    end

    test "a take at full scale is reported as clipped" do
      assert {:ok, %{clipped?: true}} = Take.decode(pcm(1.0), @rate)
    end

    test "beyond full scale is clipped, and the int16 conversion does not wrap" do
      assert {:ok, %{clipped?: true, clip: clip}} = Take.decode(pcm(1.5), @rate)

      # Every sample must land inside the signed 16-bit rails. A naive scale
      # would wrap a +1.5 sample to a large NEGATIVE one, which is the loudest
      # possible click at exactly the loudest moment of a take.
      for <<sample::little-signed-16 <- clip.data>> do
        assert sample >= -32_768 and sample <= 32_767
      end
    end

    test "digital silence is a failure, not a quiet success" do
      assert {:error, :silent_take} = Take.decode(pcm(0.0), @rate)
    end

    test "an empty buffer is refused" do
      assert {:error, :empty_take} = Take.decode(Base.encode64(<<>>), @rate)
    end

    test "a truncated float buffer is refused rather than silently shortened" do
      assert {:error, :invalid_pcm} = Take.decode(Base.encode64(<<0, 0, 0>>), @rate)
    end

    test "refuses a rate the hardware could not have produced" do
      for bad <- [0, 100, 1_000_000, "48000", nil] do
        assert {:error, :invalid_sample_rate} = Take.decode(pcm(0.5), bad)
      end
    end

    test "refuses anything that is not base64" do
      assert {:error, :invalid_pcm} = Take.decode("not base64!!", @rate)
      assert {:error, :invalid_pcm} = Take.decode(:nonsense, @rate)
    end
  end

  describe "store" do
    test "writes a WAV that SoundStudio can read back" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)

      assert {:ok, "harbor.wav"} = Take.store(take, nil, "harbor")

      path = Path.join(SoundStudio.dir(), "harbor.wav")
      assert File.exists?(path)
      assert {:ok, %SoundStudio{sample_rate: @rate, bits: 16}} = SoundStudio.read(path)
    end

    test "names the file from the word when no name is given" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)
      assert {:ok, "harbor.wav"} = Take.store(take, nil, "Harbor!")
    end

    test "an explicit name wins over the word" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)
      assert {:ok, "take-one.wav"} = Take.store(take, "take-one", "harbor")
    end

    # This test asserted that a DERIVED name collision was refused too, until
    # 08-16. That half was wrong and the corpus paid for it: the recorder could
    # capture each word exactly once, which makes a cut-up impossible by
    # construction — every word would be quote-only forever.
    #
    # The rule that survives is V.7's actual one, *"a recording is unrepeatable;
    # a name collision prompts, always"*, applied to the name the OPERATOR chose.
    test "a name the operator chose is REFUSED on collision, never overwritten" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)
      {:ok, "chosen.wav"} = Take.store(take, "chosen", "harbor")

      assert {:error, :name_taken} = Take.store(take, "chosen", "harbor")
      assert Enum.count(SoundStudio.list(), &(&1 == "chosen.wav")) == 1
    end

    test "a name derived from the word NUMBERS UP, so a word can have many takes" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)

      assert {:ok, "harbor.wav"} = Take.store(take, nil, "harbor")
      assert {:ok, "harbor-2.wav"} = Take.store(take, nil, "harbor")
      assert {:ok, "harbor-3.wav"} = Take.store(take, nil, "harbor")

      # Three files, not one overwritten three times.
      assert length(SoundStudio.list()) == 3
    end

    test "a word that normalizes to nothing is refused, not saved as track.wav" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)

      assert {:error, :name_required} = Take.store(take, nil, "!!!")
      assert {:error, :name_required} = Take.store(take, nil, nil)
      refute File.exists?(Path.join(SoundStudio.dir(), "track.wav"))
    end
  end

  describe "the index a recorded word produces" do
    test "is one manual take at confidence 1.0 spanning the whole clip" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)
      {:ok, source} = Take.store(take, nil, "harbor")

      assert {:ok, index} = Index.load(source)
      assert index.origin == :manual
      assert [%{word: "harbor", confidence: 1.0, start_ms: +0.0} = word] = index.words
      assert_in_delta word.end_ms, take.duration_ms, 0.001
    end

    test "is the corpus's first origin the aligner cannot second-guess" do
      # Every take in the voicemail corpus is `:aligned` — a proportional guess
      # capped at 0.9. This path is the only one that produces `:manual`.
      {:ok, take} = Take.decode(pcm(0.5), @rate)
      {:ok, source} = Take.store(take, nil, "harbor")

      {:ok, index} = Index.load(source)
      assert index.origin == :manual
      refute index.origin == :aligned
    end

    test "lands in the ACTIVE bank, so a contributor's take is never mis-filed" do
      {:ok, _} = Bank.create("luke")
      {:ok, "luke"} = Bank.set_active("luke")

      {:ok, take} = Take.decode(pcm(0.5), @rate)
      {:ok, source} = Take.store(take, nil, "harbor")

      assert {:ok, %{bank: "luke"}} = Index.load(source)
    end

    test "audio with no word is stored unindexed rather than refused" do
      {:ok, take} = Take.decode(pcm(0.5), @rate)

      assert {:ok, "room-tone.wav"} = Take.store(take, "room-tone", nil)
      assert File.exists?(Path.join(SoundStudio.dir(), "room-tone.wav"))
      assert {:error, :not_found} = Index.load("room-tone.wav")
    end

    test "the audio survives an index that could not be built" do
      # A take is unrepeatable, so a failed index must never discard the WAV.
      {:ok, take} = Take.decode(pcm(0.5), @rate)
      {:ok, source} = Take.store(take, "keeper", "!!!")

      assert File.exists?(Path.join(SoundStudio.dir(), source))
      assert {:error, :not_found} = Index.load(source)
    end
  end
end
