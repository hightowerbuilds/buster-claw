defmodule BusterClawWeb.Studio.VoiceStateTest do
  # async: false — points the global :workspace_root at a tmp dir, and writes
  # index files there. Same pattern as Cutup.GapsTest, which these read through.
  #
  # DataCase rather than plain ExUnit as of 08-16: `load_report/1` is now scoped
  # to the ACTIVE bank, and the active bank is a `Settings` row. That is a real
  # dependency rather than test scaffolding — the dictionary answers "what can
  # this voice say?", and it cannot know which voice without reading the pointer.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClawWeb.Studio.VoiceState, as: Voice

  setup do
    root = Path.join(System.tmp_dir!(), "bc_voice_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp save!(source, texts) do
    words =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, i} ->
        %{text: text, start_ms: i * 500, end_ms: i * 500 + 300, confidence: 0.8}
      end)

    {:ok, index} = Index.build(source, words, origin: :aligned)
    :ok = Index.save(index)
  end

  # "boat" three times, "harbor" twice, "fog" once. So boat and harbor are
  # cuttable and fog is a quotation — the distinction this whole surface exists
  # to show.
  defp corpus do
    save!("a.wav", ["Boat", "harbor", "boat", "fog"])
    save!("b.wav", ["boat", "harbor"])
  end

  # A socket is a map with assigns as far as these functions are concerned, and
  # building one by hand keeps this file free of LiveView plumbing — the point
  # of `Studio.VoiceState` being socket-in/socket-out.
  defp loaded do
    corpus()
    socket = Voice.load_report(%Phoenix.LiveView.Socket{})
    socket.assigns
  end

  describe "load_report/1" do
    test "an unreadable corpus is a report of zeros, not an error" do
      # No index directory at all: a dev workspace legitimately has none.
      assigns = Voice.load_report(%Phoenix.LiveView.Socket{}).assigns

      assert assigns.voice_error == nil
      assert assigns.voice_report.distinct_words == 0
      assert assigns.voice_report.indexed_sources == 0
    end

    test "reads the corpus into the socket" do
      assigns = loaded()

      assert assigns.voice_report.indexed_sources == 2
      assert assigns.voice_report.distinct_words == 3
      assert assigns.voice_report.total_takes == 6
    end
  end

  describe "ensure_report/1" do
    test "loads once and does not re-read" do
      corpus()
      socket = Voice.ensure_report(%Phoenix.LiveView.Socket{})
      first = socket.assigns.voice_report

      # Delete the corpus underneath it. A second ensure must NOT notice, which
      # is the whole point: switching sub-tabs cannot re-read ten files.
      File.rm_rf!(Path.dirname(Index.dir()))

      assert Voice.ensure_report(socket).assigns.voice_report == first
      # …while an explicit refresh does re-read, and now finds nothing.
      assert Voice.load_report(socket).assigns.voice_report.indexed_sources == 0
    end
  end

  describe "vocabulary/2" do
    test "is ordered by take count, and marks nothing itself" do
      assert Voice.vocabulary(loaded(), "") == [{"boat", 3}, {"harbor", 2}, {"fog", 1}]
    end

    test "filters on the NORMALISED word, which is what the corpus is keyed on" do
      assigns = loaded()

      assert Voice.vocabulary(assigns, "boa") == [{"boat", 3}]
      # Case and punctuation are normalised away, so a query carrying them still
      # finds the entry that exists.
      assert Voice.vocabulary(assigns, "BOAT") == [{"boat", 3}]
      assert Voice.vocabulary(assigns, "zzz") == []
    end

    test "matches anywhere in the word, not just its start" do
      # Deliberate: hunting for a word you half-remember is the common use, and
      # "bo" finding harBOr is the behaviour that serves it. Asserted rather
      # than assumed, because a later prefix-match "fix" would look like a
      # tightening and would quietly remove that.
      assert Voice.vocabulary(loaded(), "bo") == [{"boat", 3}, {"harbor", 2}]
    end

    test "an unloaded report is an empty list, never a crash" do
      assert Voice.vocabulary(%{voice_report: nil}, "boat") == []
    end
  end

  describe "sentence_check/2" do
    test "grades every word: cuttable, quotable, missing" do
      rows = Voice.sentence_check(loaded(), "boat fog kayak")

      assert [
               %{word: "boat", takes: 3, verdict: :cuttable},
               %{word: "fog", takes: 1, verdict: :quotable},
               %{word: "kayak", takes: 0, verdict: :missing}
             ] = rows
    end

    test "one take is :quotable and NOT :cuttable — the distinction is the point" do
      [row] = Voice.sentence_check(loaded(), "fog")

      assert row.verdict == :quotable
      refute row.verdict == :cuttable
    end

    test "keeps the word as typed while grading the normalised form" do
      [row] = Voice.sentence_check(loaded(), "Boat,")

      assert row.text == "Boat,"
      assert row.word == "boat"
      assert row.verdict == :cuttable
    end

    test "tokens that normalise to nothing are dropped, not reported missing" do
      # Bare punctuation has no word to look for, and reporting it as missing
      # would put something in a donor passage that can never be recorded.
      assert Voice.sentence_check(loaded(), "boat -- ...") == [
               %{text: "boat", word: "boat", takes: 3, verdict: :cuttable}
             ]
    end

    test "order follows the phrase, not the corpus" do
      rows = Voice.sentence_check(loaded(), "fog boat harbor")
      assert Enum.map(rows, & &1.word) == ["fog", "boat", "harbor"]
    end
  end

  describe "sentence_summary/1" do
    test "counts each verdict" do
      summary =
        loaded() |> Voice.sentence_check("boat fog kayak boat") |> Voice.sentence_summary()

      assert summary == %{cuttable: 2, quotable: 1, missing: 1}
    end

    test "an empty phrase is three zeros" do
      assert Voice.sentence_summary([]) == %{cuttable: 0, quotable: 0, missing: 0}
    end
  end

  describe "put_query/2 and put_sentence/2" do
    test "hold what was typed" do
      socket =
        %Phoenix.LiveView.Socket{} |> Voice.put_query("bo") |> Voice.put_sentence("boat fog")

      assert socket.assigns.voice_query == "bo"
      assert socket.assigns.voice_sentence == "boat fog"
    end

    test "a non-binary is ignored rather than crashing the LiveView" do
      socket = %Phoenix.LiveView.Socket{} |> Voice.assign_voice()

      assert Voice.put_query(socket, nil).assigns.voice_query == ""
      assert Voice.put_sentence(socket, 42).assigns.voice_sentence == ""
    end
  end
end
