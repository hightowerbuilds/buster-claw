defmodule BusterClaw.Notifications.Cutup.GapsTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Cutup.Gaps
  alias BusterClaw.Notifications.Cutup.Index

  # The corpus lives under the operator's configured DataZone, never under
  # `tmp/dev-workspace`, so every assertion here is made against index files this
  # test writes itself. Same temp-workspace pattern as `Cutup.IndexTest`.
  setup do
    root = Path.join(System.tmp_dir!(), "bc_gaps_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A word list in the shape a recognizer emits: `text` as heard, timings in ms.
  defp save!(source, texts, opts \\ []) do
    words =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, i} ->
        %{text: text, start_ms: i * 500, end_ms: i * 500 + 300, confidence: 0.8}
      end)

    {:ok, index} = Index.build(source, words, opts)
    :ok = Index.save(index)
    index
  end

  # Two sources whose overlap is the whole point: "boat" is said three times,
  # "harbor" twice, and "fog" and "tide" exactly once each.
  defp corpus do
    save!("a.wav", ["Boat", "harbor", "boat", "fog"], origin: :aligned)
    save!("b.wav", ["boat", "Harbor!", "tide"], origin: :recognizer)
  end

  describe "report/1 on an empty workspace" do
    test "an unindexed workspace is zeros, not an error" do
      assert {:ok, report} = Gaps.report()

      assert report.indexed_sources == 0
      assert report.unreadable_sources == 0
      assert report.distinct_words == 0
      assert report.total_takes == 0
      assert report.cuttable == 0
      assert report.single_take == []
      assert report.by_take_count == []
    end

    test "an existing but empty index directory is also zeros" do
      :ok = File.mkdir_p(Index.dir())

      assert {:ok, %{indexed_sources: 0, distinct_words: 0}} = Gaps.report()
    end

    test "origins keep their full shape so a caller never has to nil-check" do
      assert {:ok, report} = Gaps.report()

      assert report.origins == %{
               "aligned" => 0,
               "manual" => 0,
               "recognizer" => 0,
               "imported" => 0
             }
    end

    test "every target word is missing when there is no corpus" do
      assert {:ok, %{missing: ["boat", "harbor"]}} = Gaps.report(target: ["harbor", "Boat"])
    end
  end

  describe "report/1 on a populated corpus" do
    test "counts sources, distinct words and takes" do
      corpus()

      assert {:ok, report} = Gaps.report()

      assert report.indexed_sources == 2
      assert report.unreadable_sources == 0
      assert report.distinct_words == 4
      assert report.total_takes == 7
    end

    test "single_take is exactly the words with one take, and cuttable its complement" do
      corpus()

      assert {:ok, report} = Gaps.report()

      # "boat" (3) and "harbor" (2) are cuttable; "fog" and "tide" are quotations.
      assert report.single_take == ["fog", "tide"]
      assert report.cuttable == 2
      refute "boat" in report.single_take
      refute "harbor" in report.single_take
    end

    test "a second take moves a word out of single_take" do
      save!("a.wav", ["fog"])

      assert {:ok, %{single_take: ["fog"], cuttable: 0}} = Gaps.report()

      save!("b.wav", ["Fog."])

      assert {:ok, %{single_take: [], cuttable: 1, distinct_words: 1, total_takes: 2}} =
               Gaps.report()
    end

    test "by_take_count is count descending, then alphabetical" do
      corpus()

      assert {:ok, report} = Gaps.report()

      assert report.by_take_count == [{"boat", 3}, {"harbor", 2}, {"fog", 1}, {"tide", 1}]
    end

    test "takes are grouped on the normalized word, not the surface text" do
      save!("a.wav", ["Boat,", "boat", "BOAT"])

      assert {:ok, %{distinct_words: 1, by_take_count: [{"boat", 3}]}} = Gaps.report()
    end

    test ":limit caps by_take_count after sorting, keeping the best-covered words" do
      corpus()

      assert {:ok, %{by_take_count: ranked} = report} = Gaps.report(limit: 2)

      assert ranked == [{"boat", 3}, {"harbor", 2}]
      # The cap is presentational: the counts it summarizes stay whole.
      assert report.distinct_words == 4
      assert report.single_take == ["fog", "tide"]
    end

    test "a limit that is not a positive integer is ignored, not refused" do
      corpus()

      assert {:ok, %{by_take_count: full}} = Gaps.report()
      assert {:ok, %{by_take_count: ^full}} = Gaps.report(limit: 0)
      assert {:ok, %{by_take_count: ^full}} = Gaps.report(limit: "two")
    end

    test "origins count takes and inherit the file header, summing to total_takes" do
      corpus()

      assert {:ok, report} = Gaps.report()

      assert report.origins == %{
               "aligned" => 4,
               "recognizer" => 3,
               "manual" => 0,
               "imported" => 0
             }

      assert report.origins |> Map.values() |> Enum.sum() == report.total_takes
    end
  end

  describe "report/1 with a target vocabulary" do
    test "missing is only the target words with zero takes" do
      corpus()

      assert {:ok, report} = Gaps.report(target: ["boat", "tide", "seagull", "pier"])

      assert report.missing == ["pier", "seagull"]
    end

    test "a target word with one take is present but not cuttable" do
      corpus()

      assert {:ok, report} = Gaps.report(target: ["fog"])

      assert report.missing == []
      assert "fog" in report.single_take
    end

    test "target words are normalized and de-duplicated" do
      corpus()

      assert {:ok, %{missing: ["seagull"]}} =
               Gaps.report(target: ["Seagull!", "seagull", "BOAT"])
    end

    test "a target given as one string is split on whitespace" do
      corpus()

      # "the" is repeated in the phrase and de-duplicated; only "boat" is covered.
      assert {:ok, %{missing: ["at", "pier", "the"]}} =
               Gaps.report(target: "the boat at the pier")
    end

    test "a target entry that normalizes to nothing is dropped, not reported missing" do
      corpus()

      assert {:ok, %{missing: []}} = Gaps.report(target: ["...", "boat"])
    end

    test "missing is absent unless a target was given" do
      corpus()

      assert {:ok, report} = Gaps.report()
      refute Map.has_key?(report, :missing)
    end

    test "a target that is not a list of strings is refused" do
      assert {:error, :invalid_target} = Gaps.report(target: [:boat])
      assert {:error, :invalid_target} = Gaps.report(target: 42)
    end
  end

  describe "report/1 tolerance" do
    test "a corrupt index is counted rather than silently dropped" do
      corpus()
      File.write!(Path.join(Index.dir(), "c.wav.index.json"), "{not json")

      assert {:ok, report} = Gaps.report()

      assert report.indexed_sources == 2
      assert report.unreadable_sources == 1
      assert report.total_takes == 7
    end

    test "non-index files in the directory are not sources at all" do
      corpus()
      File.write!(Path.join(Index.dir(), "notes.txt"), "ignore me")

      assert {:ok, %{indexed_sources: 2, unreadable_sources: 0}} = Gaps.report()
    end

    test "a file where the index directory belongs is an error, not zeros" do
      dir = Index.dir()
      :ok = File.mkdir_p(Path.dirname(dir))
      File.write!(dir, "not a directory")

      assert {:error, reason} = Gaps.report()
      assert reason in [:enotdir, :eacces]
    end

    test "opts must be a keyword list" do
      assert {:error, :invalid_opts} = Gaps.report(%{target: ["boat"]})
    end
  end
end
