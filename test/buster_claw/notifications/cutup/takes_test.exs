defmodule BusterClaw.Notifications.Cutup.TakesTest do
  @moduledoc """
  `Cutup.Takes` — curating the takes of a word.

  DataCase because preferences live in `Settings`. The deletion half needs no
  database and is exercised through the same setup for convenience.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Takes
  alias BusterClaw.Notifications.SoundStudio

  @bank "voicemail"

  setup do
    root = Path.join(System.tmp_dir!(), "bc_takes_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    File.mkdir_p!(SoundStudio.dir())

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A source with real audio on disk and an index describing it.
  defp source(name, words, origin) do
    clip = %SoundStudio{
      sample_rate: 22_050,
      channels: 1,
      bits: 16,
      data: <<0, 1>> |> :binary.copy(2205)
    }

    :ok = SoundStudio.write(clip, Path.join(SoundStudio.dir(), name))

    entries =
      words
      |> Enum.with_index()
      |> Enum.map(fn {word, i} ->
        %{text: word, start_ms: i * 500.0, end_ms: i * 500.0 + 300.0, confidence: 0.8}
      end)

    {:ok, index} = Index.build(name, entries, origin: origin, bank: @bank)
    :ok = Index.save(index)
    name
  end

  describe "delete" do
    # The row that was UNCOVERED until this file existed: breaking the
    # `origin: :manual` half of the guard failed no test, which means a voicemail
    # could have lost its audio and nothing would have said so.
    test "a source that is NOT a one-word recording keeps its audio when emptied" do
      source("voicemail-03.wav", ["hello"], :aligned)

      assert {:ok, %{index: true, audio: false}} = Takes.delete("voicemail-03.wav", 0.0)

      # The index is gone; the master is not. V.7: masters are the only way back.
      assert {:error, :not_found} = Index.load("voicemail-03.wav")
      assert "voicemail-03.wav" in SoundStudio.list()
    end

    test "a one-word :manual recording takes its audio with it" do
      source("harbor.wav", ["harbor"], :manual)

      assert {:ok, %{index: true, audio: true}} = Takes.delete("harbor.wav", 0.0)
      assert SoundStudio.list() == []
    end

    test "a sentence loses one entry and keeps the rest, and the audio" do
      source("line.wav", ~w(the harbor is quiet), :aligned)

      assert {:ok, %{index: false, audio: false}} = Takes.delete("line.wav", 500.0)

      {:ok, index} = Index.load("line.wav")
      assert Enum.map(index.words, & &1.word) == ~w(the is quiet)
      assert "line.wav" in SoundStudio.list()
    end

    test "an offset that names no take is refused rather than deleting the nearest" do
      source("line.wav", ~w(the harbor), :aligned)

      assert {:error, :no_such_take} = Takes.delete("line.wav", 12_345.0)
      assert {:ok, %{words: [_, _]}} = Index.load("line.wav")
    end
  end

  describe "prefer" do
    test "is a pointer — it changes no take's confidence" do
      source("one.wav", ["harbor"], :aligned)
      {:ok, before} = Index.load("one.wav")

      {:ok, _} = Takes.prefer(@bank, "harbor", "one.wav", 0.0)

      assert {:ok, ^before} = Index.load("one.wav")
    end

    test "survives a round trip through storage, offsets included" do
      source("line.wav", ~w(the harbor), :aligned)

      {:ok, _} = Takes.prefer(@bank, "harbor", "line.wav", 500.0)

      assert %{source: "line.wav", start_ms: 500.0} = Takes.preferred(@bank, "harbor")
    end

    test "list/2 marks exactly the preferred take" do
      source("one.wav", ["harbor"], :aligned)
      source("two.wav", ["harbor"], :aligned)
      {:ok, _} = Takes.prefer(@bank, "harbor", "two.wav", 0.0)

      marked = Takes.list(@bank, "harbor") |> Enum.filter(& &1.preferred?)

      assert [%{source: "two.wav"}] = marked
    end

    test "pin/3 narrows to the chosen take, and falls through when it is gone" do
      source("one.wav", ["harbor"], :aligned)
      source("two.wav", ["harbor"], :aligned)

      hits = Index.search("harbor", bank: @bank)
      assert length(hits) == 2

      {:ok, _} = Takes.prefer(@bank, "harbor", "two.wav", 0.0)
      assert [%{source: "two.wav"}] = Takes.pin(hits, @bank, "harbor")

      # Dangling: the take is deleted but the pointer remains. Falling through is
      # the contract — a stale preference costs a worse splice, never a refusal.
      {:ok, _} = Takes.delete("two.wav", 0.0)
      remaining = Index.search("harbor", bank: @bank)
      assert Takes.pin(remaining, @bank, "harbor") == remaining
    end

    test "prune drops preferences whose takes are gone, and keeps the rest" do
      source("one.wav", ["harbor"], :aligned)
      source("two.wav", ["hello"], :aligned)

      {:ok, _} = Takes.prefer(@bank, "harbor", "one.wav", 0.0)
      {:ok, _} = Takes.prefer(@bank, "hello", "two.wav", 0.0)
      {:ok, _} = Takes.delete("one.wav", 0.0)

      :ok = Takes.prune()

      refute Takes.preferred(@bank, "harbor")
      assert Takes.preferred(@bank, "hello")
    end
  end
end
