defmodule BusterClaw.Notifications.Cutup.IndexTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Cutup.Index

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cutup_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A word list in the shape a recognizer emits: `text` as heard, timings in ms.
  defp words(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{text, confidence}, i} ->
      %{text: text, start_ms: i * 500, end_ms: i * 500 + 300, confidence: confidence}
    end)
  end

  defp save!(source, pairs, opts \\ []) do
    {:ok, index} = Index.build(source, words(pairs), opts)
    :ok = Index.save(index)
    index
  end

  describe "build/3" do
    test "normalizes on the way in, keeping the recognized text" do
      {:ok, index} =
        Index.build("a.wav", [%{text: "Harbor,", start_ms: 10, end_ms: 90, confidence: 0.8}])

      assert [%{word: "harbor", text: "Harbor,"}] = index.words
      assert index.source == "a.wav"
      assert index.origin == :manual
    end

    test "sorts by start time, because phrase search calls adjacency 'consecutive'" do
      {:ok, index} =
        Index.build("a.wav", [
          %{text: "world", start_ms: 900, end_ms: 1000, confidence: 1.0},
          %{text: "hello", start_ms: 100, end_ms: 200, confidence: 1.0}
        ])

      assert Enum.map(index.words, & &1.word) == ["hello", "world"]
    end

    test "accepts string keys and a bare `word` with no `text`" do
      {:ok, index} =
        Index.build("a.wav", [
          %{"word" => "Boat", "start_ms" => 0, "end_ms" => 100, "confidence" => 0.5}
        ])

      assert [%{word: "boat", text: "Boat", confidence: 0.5}] = index.words
    end

    test "drops unusable entries instead of failing the whole index" do
      {:ok, index} =
        Index.build("a.wav", [
          %{text: "keep", start_ms: 0, end_ms: 100, confidence: 1.0},
          # not a map
          "nope",
          # pure punctuation normalizes to nothing
          %{text: "—", start_ms: 100, end_ms: 200, confidence: 1.0},
          # zero-length span is silence, not a word
          %{text: "gone", start_ms: 300, end_ms: 300, confidence: 1.0},
          # missing bounds
          %{text: "also gone", confidence: 1.0},
          # negative start
          %{text: "bad", start_ms: -5, end_ms: 100, confidence: 1.0}
        ])

      assert Enum.map(index.words, & &1.word) == ["keep"]
    end

    test "a missing confidence reads as 1.0, and out-of-range values clamp" do
      {:ok, index} =
        Index.build("a.wav", [
          %{text: "bare", start_ms: 0, end_ms: 100},
          %{text: "hot", start_ms: 200, end_ms: 300, confidence: 7.0},
          %{text: "cold", start_ms: 400, end_ms: 500, confidence: -2.0}
        ])

      assert Enum.map(index.words, & &1.confidence) == [1.0, 1.0, 0.0]
    end

    test "origin is validated, from an atom or a string" do
      assert {:ok, %{origin: :recognizer}} = Index.build("a.wav", [], origin: :recognizer)
      assert {:ok, %{origin: :imported}} = Index.build("a.wav", [], origin: "imported")
      assert {:error, :invalid_origin} = Index.build("a.wav", [], origin: :guessed)
    end

    test "a non-list word list is refused rather than raising" do
      assert {:error, :invalid_index} = Index.build("a.wav", "harbor", [])
    end
  end

  describe "save/1 and load/1" do
    test "round-trips an index" do
      saved = save!("voicemail-03.wav", [{"Harbor", 0.9}, {"lights", 0.4}], language: "en-US")

      assert {:ok, loaded} = Index.load("voicemail-03.wav")
      assert loaded.source == "voicemail-03.wav"
      assert loaded.language == "en-US"
      assert loaded.origin == saved.origin
      assert Enum.map(loaded.words, & &1.word) == ["harbor", "lights"]
      assert Enum.map(loaded.words, & &1.text) == ["Harbor", "lights"]
      assert Enum.map(loaded.words, & &1.confidence) == [0.9, 0.4]
      assert [%{start_ms: +0.0, end_ms: 300.0} | _] = loaded.words
      assert %DateTime{} = loaded.indexed_at
    end

    test "the file lands in sounds/studio/index/, alongside the sources" do
      save!("voicemail-03.wav", [{"harbor", 1.0}])

      assert Path.relative_to(Index.dir(), Application.get_env(:buster_claw, :workspace_root)) ==
               "sounds/studio/index"

      assert File.exists?(Path.join(Index.dir(), "voicemail-03.wav.index.json"))
    end

    test "the directory is created on demand" do
      refute File.dir?(Index.dir())
      save!("a.wav", [{"one", 1.0}])
      assert File.dir?(Index.dir())
    end

    test "sources differing only by audio extension index separately" do
      save!("clip.wav", [{"wav", 1.0}])
      save!("clip.mp3", [{"mp3", 1.0}])

      assert {:ok, %{words: [%{word: "wav"}]}} = Index.load("clip.wav")
      assert {:ok, %{words: [%{word: "mp3"}]}} = Index.load("clip.mp3")
    end

    test "an absent index is :not_found" do
      assert {:error, :not_found} = Index.load("never-seen.wav")
    end

    test "corrupt JSON is :invalid, not a raise" do
      save!("a.wav", [{"harbor", 1.0}])
      File.write!(Path.join(Index.dir(), "a.wav.index.json"), "{\"words\": [ {oh no")

      assert {:error, :invalid} = Index.load("a.wav")
    end

    test "well-formed JSON that is not an index is :invalid" do
      File.mkdir_p!(Index.dir())
      File.write!(Path.join(Index.dir(), "a.wav.index.json"), ~s({"hello": "world"}))
      assert {:error, :invalid} = Index.load("a.wav")

      File.write!(Path.join(Index.dir(), "b.wav.index.json"), ~s([1, 2, 3]))
      assert {:error, :invalid} = Index.load("b.wav")
    end

    test "a hand-edited file survives: junk words drop, order is restored" do
      File.mkdir_p!(Index.dir())

      File.write!(
        Path.join(Index.dir(), "a.wav.index.json"),
        ~s({"words": [
             {"text": "second", "start_ms": 900, "end_ms": 1000},
             "not a word at all",
             {"text": "first", "start_ms": 10, "end_ms": 100, "confidence": 0.3}
           ], "origin": "nonsense", "indexed_at": "not a date"})
      )

      assert {:ok, index} = Index.load("a.wav")
      assert Enum.map(index.words, & &1.word) == ["first", "second"]
      # A degraded field is not an unopenable file.
      assert index.origin == :manual
      assert index.indexed_at == nil
    end

    test "the filename wins over a disagreeing `source` inside the file" do
      File.mkdir_p!(Index.dir())

      File.write!(
        Path.join(Index.dir(), "a.wav.index.json"),
        ~s({"source": "/etc/passwd", "words": []})
      )

      assert {:ok, %{source: "a.wav"}} = Index.load("a.wav")
    end

    test "saving a hand-built map re-normalizes it before it lands" do
      index = %{
        source: "a.wav",
        words: [
          %{word: "SECOND!", text: "Second!", start_ms: 900, end_ms: 1000, confidence: 0.2},
          %{word: "First", text: "First", start_ms: 10, end_ms: 100, confidence: 0.9}
        ],
        origin: :manual,
        language: nil,
        indexed_at: nil
      }

      assert :ok = Index.save(index)
      assert {:ok, loaded} = Index.load("a.wav")
      assert Enum.map(loaded.words, & &1.word) == ["first", "second"]
    end

    test "a non-map is refused" do
      assert {:error, :invalid_index} = Index.save("harbor")
      assert {:error, :invalid_index} = Index.save(%{words: []})
    end

    test "load of a non-binary source is refused" do
      assert {:error, :invalid_source} = Index.load(nil)
      assert {:error, :invalid_source} = Index.load(:a)
    end
  end

  describe "the source is a basename, never a path" do
    @traversals [
      "../../etc/passwd",
      "..",
      "../a.wav",
      "a/../../b.wav",
      "/etc/passwd",
      "sub/a.wav",
      "..\\windows\\system32",
      "a.wav\0.txt",
      ".",
      ""
    ]

    test "every entry point refuses a traversal attempt" do
      for source <- @traversals do
        assert {:error, :invalid_source} = Index.load(source),
               "load/1 accepted #{inspect(source)}"

        assert {:error, :invalid_source} = Index.delete(source),
               "delete/1 accepted #{inspect(source)}"

        assert {:error, :invalid_source} = Index.build(source, []),
               "build/3 accepted #{inspect(source)}"

        assert {:error, :invalid_source} = Index.save(%{source: source, words: []}),
               "save/1 accepted #{inspect(source)}"
      end
    end

    test "no file is written outside the index directory" do
      escape =
        Path.join(System.tmp_dir!(), "bc_cutup_escape_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(escape) end)

      assert {:error, :invalid_source} =
               Index.save(%{source: Path.join(escape, "evil.json"), words: []})

      refute File.exists?(escape)
      assert Index.list() == []
    end

    test "a name the audio sanitizer would rewrite is refused, not silently renamed" do
      assert {:error, :unsafe_source} = Index.build("weird\tname*.wav", [])
      assert {:error, :unsafe_source} = Index.load("weird\tname*.wav")
    end

    test "an uppercase extension is still a legal source" do
      assert {:ok, _index} = Index.build("VOICE.WAV", [])
      save!("VOICE.WAV", [{"harbor", 1.0}])
      assert Index.list() == ["VOICE.WAV"]
    end

    test "a search restricted to an unsafe source finds nothing rather than raising" do
      save!("a.wav", [{"harbor", 1.0}])
      assert Index.search("harbor", source: "../../a.wav") == []
      assert Index.words_available(source: "../../a.wav") == %{}
    end
  end

  describe "list/0, indexed?/1 and delete/1" do
    test "an absent directory lists as empty rather than erroring" do
      assert Index.list() == []
      refute Index.indexed?("a.wav")
    end

    test "lists the sources that have indexes, sorted, ignoring strays" do
      save!("beta.wav", [{"one", 1.0}])
      save!("Alpha.wav", [{"two", 1.0}])
      File.write!(Path.join(Index.dir(), "README.md"), "not an index")

      assert Index.list() == ["Alpha.wav", "beta.wav"]
      assert Index.indexed?("beta.wav")
      refute Index.indexed?("README.md")
      refute Index.indexed?(nil)
    end

    test "delete removes the index and leaves the rest alone" do
      save!("a.wav", [{"one", 1.0}])
      save!("b.wav", [{"two", 1.0}])

      assert :ok = Index.delete("a.wav")
      assert Index.list() == ["b.wav"]
      assert {:error, :not_found} = Index.load("a.wav")
    end

    test "deleting what is not there is :not_found" do
      assert {:error, :not_found} = Index.delete("a.wav")
      assert {:error, :invalid_source} = Index.delete(nil)
    end
  end

  describe "search/2 — single words" do
    setup do
      save!("one.wav", [{"The", 0.99}, {"harbor", 0.40}, {"lights", 0.90}])
      save!("two.wav", [{"Harbor!", 0.85}, {"is", 0.70}, {"cold", 0.60}])
      :ok
    end

    test "finds a word across every index, ignoring case and punctuation" do
      hits = Index.search("HARBOR")

      assert Enum.map(hits, & &1.source) == ["two.wav", "one.wav"]
      assert Enum.map(hits, & &1.word.text) == ["Harbor!", "harbor"]
    end

    test "the best take is first" do
      assert [%{word: %{confidence: 0.85}}, %{word: %{confidence: 0.4}}] =
               Index.search("harbor")
    end

    test "a hit carries the span to splice" do
      assert [%{source: "two.wav", word: %{start_ms: +0.0, end_ms: 300.0}} | _] =
               Index.search("harbor")
    end

    test "a word nobody said finds nothing" do
      assert Index.search("submarine") == []
    end

    test ":source restricts the search" do
      assert [%{source: "one.wav"}] = Index.search("harbor", source: "one.wav")
      assert Index.search("harbor", source: "nope.wav") == []
    end

    test ":min_confidence filters, and :limit keeps the best" do
      assert [%{source: "two.wav"}] = Index.search("harbor", min_confidence: 0.5)
      assert Index.search("harbor", min_confidence: 0.99) == []
      assert [%{source: "two.wav"}] = Index.search("harbor", limit: 1)
      assert length(Index.search("harbor", limit: 99)) == 2
    end

    test "nonsense options are ignored rather than fatal" do
      assert length(Index.search("harbor", limit: 0)) == 2
      assert length(Index.search("harbor", limit: "one")) == 2
      assert length(Index.search("harbor", min_confidence: :high)) == 2
    end

    test "an unusable query finds nothing instead of raising" do
      assert Index.search(nil) == []
      assert Index.search(:harbor) == []
      assert Index.search("") == []
      assert Index.search("   ") == []
      assert Index.search(",,, ---") == []
      assert Index.search("harbor", "not opts") == []
    end
  end

  describe "search/2 — phrases" do
    setup do
      save!("one.wav", [{"call", 0.90}, {"me", 0.80}, {"back", 0.95}, {"soon", 0.99}])
      save!("two.wav", [{"call", 0.50}, {"the", 0.99}, {"harbor", 0.99}, {"back", 0.99}])
      :ok
    end

    test "matches consecutive words in one source" do
      assert [hit] = Index.search("call me back")
      assert hit.source == "one.wav"
      assert hit.word.word == "call me back"
      assert hit.word.text == "call me back"
    end

    test "the hit spans the whole phrase, so it splices as one cut" do
      assert [%{word: %{start_ms: +0.0, end_ms: 1300.0}}] = Index.search("call me back")
    end

    test "confidence is the worst word in the phrase, not the average" do
      # 0.90 / 0.80 / 0.95 — the mean would be 0.883 and would hide the "me".
      assert [%{word: %{confidence: 0.8}}] = Index.search("call me back")
    end

    test "does NOT match non-consecutive words" do
      # two.wav says "call the harbor back" — "call back" is not in it.
      assert Index.search("call back") == []
    end

    test "a phrase spanning two sources is not a phrase" do
      # one.wav ends "…back soon", two.wav starts "call…" — no cross-source match.
      assert Index.search("soon call") == []
    end

    test "punctuation and case in the query do not matter" do
      assert [_hit] = Index.search("  Call, ME —  back!  ")
    end

    test "a phrase honours :min_confidence against its weakest word" do
      assert [_hit] = Index.search("call me back", min_confidence: 0.8)
      assert Index.search("call me back", min_confidence: 0.81) == []
    end

    test "a phrase longer than the index matches nothing" do
      assert Index.search("call me back soon enough please", source: "one.wav") == []
    end

    test "repeated phrases each come back as their own hit, best first" do
      save!("three.wav", [{"go", 0.20}, {"now", 0.60}, {"go", 0.90}, {"now", 0.70}])

      hits = Index.search("go now", source: "three.wav")

      assert length(hits) == 2
      assert Enum.map(hits, & &1.word.confidence) == [0.7, 0.2]
      assert Enum.map(hits, & &1.word.start_ms) == [1000.0, 0.0]
    end
  end

  describe "words_available/1 and takes/2" do
    test "an empty corpus is an empty map, not an error" do
      assert Index.words_available() == %{}
      assert Index.takes("harbor") == 0
    end

    test "counts every usable take of every word across the corpus" do
      save!("one.wav", [{"The", 0.9}, {"harbor", 0.4}, {"harbor", 0.8}])
      save!("two.wav", [{"Harbor!", 0.85}, {"lights", 0.7}])

      assert Index.words_available() == %{
               "the" => 1,
               "harbor" => 3,
               "lights" => 1
             }
    end

    test "narrows by source and by confidence" do
      save!("one.wav", [{"harbor", 0.4}, {"harbor", 0.8}])
      save!("two.wav", [{"harbor", 0.9}])

      assert Index.words_available(source: "one.wav") == %{"harbor" => 2}
      assert Index.words_available(min_confidence: 0.85) == %{"harbor" => 1}
      assert Index.words_available(min_confidence: 0.99) == %{}
      assert Index.words_available("not opts") == %{}
    end

    test "takes/2 answers the one question that decides a cut-up" do
      save!("one.wav", [{"harbor", 0.4}, {"harbor", 0.8}])

      assert Index.takes("harbor") == 2
      assert Index.takes("harbor", min_confidence: 0.5) == 1
      assert Index.takes("submarine") == 0
    end
  end

  describe "normalize_word/1" do
    test "lowercases and strips punctuation" do
      assert Index.normalize_word("Harbor,") == "harbor"
      assert Index.normalize_word("don't") == "dont"
      assert Index.normalize_word("—") == ""
    end

    test "anything that is not a binary normalizes to nothing" do
      assert Index.normalize_word(nil) == ""
      assert Index.normalize_word(42) == ""
    end
  end
end
