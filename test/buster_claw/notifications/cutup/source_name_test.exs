defmodule BusterClaw.Notifications.Cutup.SourceNameTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Cutup.Features
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.SourceName

  setup do
    root = Path.join(System.tmp_dir!(), "bc_srcname_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # Every shape that must never become a filename. The union of what `Index` and
  # `Features` each tested separately while they carried their own copy of the
  # gate — kept as one list here because there is one gate now, and a name only
  # one store's list happened to cover is how the previous asymmetry survived.
  @traversals [
    "../../etc/passwd",
    "../a.wav",
    "a/../../b.wav",
    "..",
    ".",
    "",
    "/etc/passwd",
    "sub/a.wav",
    "..\\windows\\system32",
    "..\\evil.wav",
    "a.wav\0.txt",
    "a\0.wav"
  ]

  describe "safe/1" do
    test "refuses every traversal shape as :invalid_source" do
      for source <- @traversals do
        assert {:error, :invalid_source} = SourceName.safe(source),
               "the gate accepted #{inspect(source)}"
      end
    end

    test "refuses a legal basename the audio sanitizer would rewrite, as :unsafe_source" do
      # A different error from a traversal on purpose: the fix is different. This
      # one is refused rather than sanitized, because a store that renamed on the
      # way in would write a file the caller could not then load by.
      assert {:error, :unsafe_source} = SourceName.safe("we?ird.wav")
      assert {:error, :unsafe_source} = SourceName.safe("weird\tname*.wav")
    end

    test "refuses a non-binary rather than raising" do
      for term <- [nil, :a, 123, ["a.wav"], %{}] do
        assert {:error, :invalid_source} = SourceName.safe(term), inspect(term)
      end
    end

    test "accepts an ordinary basename and returns it unchanged" do
      assert {:ok, "voicemail-03.wav"} = SourceName.safe("voicemail-03.wav")
      assert {:ok, "a name (2).mp3"} = SourceName.safe("a name (2).mp3")
    end

    test "an uppercase extension is a legal source, not a sanitizer rewrite" do
      # `safe_name/1` downcases the extension it re-attaches, so an exact
      # comparison would refuse a real file for a difference that is not a
      # safety difference.
      assert {:ok, "VOICE.WAV"} = SourceName.safe("VOICE.WAV")
    end
  end

  describe "both stores share one gate" do
    # The gate is one function now, but the property that matters to a reader is
    # about the STORES: neither may accept a name the other refuses. Asserting it
    # at the public entry points means this still fails if someone re-introduces
    # a private copy in either module.
    test "every public entry point of Index and Features refuses every traversal" do
      for source <- @traversals do
        assert {:error, :invalid_source} = Index.load(source), "Index.load/1: #{inspect(source)}"
        assert {:error, :invalid_source} = Index.delete(source)
        assert {:error, :invalid_source} = Index.build(source, [])
        assert {:error, :invalid_source} = Index.save(%{source: source, words: []})

        assert {:error, :invalid_source} = Features.for_source(source),
               "Features.for_source/2: #{inspect(source)}"

        assert {:error, :invalid_source} = Features.delete(source)
        refute Features.cached?(source)
      end
    end

    test "both stores refuse a sanitizer-rewritten name with the same atom" do
      assert {:error, :unsafe_source} = Index.build("we?ird.wav", [])
      assert {:error, :unsafe_source} = Index.load("we?ird.wav")
      assert {:error, :unsafe_source} = Features.for_source("we?ird.wav")
      assert {:error, :unsafe_source} = Features.delete("we?ird.wav")
    end

    test "no traversal name writes anything outside either store's directory" do
      for source <- @traversals do
        Index.save(%{source: source, words: []})
        Index.delete(source)
        Features.for_source(source)
        Features.delete(source)
      end

      assert Index.list() == []
      assert Features.list() == []
    end
  end

  describe "list_in/2" do
    test "an absent directory lists as empty rather than raising" do
      assert SourceName.list_in(
               Path.join(System.tmp_dir!(), "nope-#{System.unique_integer()}"),
               ".x"
             ) ==
               []
    end

    test "strips the suffix, sorts case-insensitively, and ignores everything else" do
      dir = Path.join(System.tmp_dir!(), "bc_listin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      for name <- ["b.wav.x", "A.wav.x", "notes.txt", "c.wav.x"],
          do: File.write!(dir <> "/" <> name, "")

      assert SourceName.list_in(dir, ".x") == ["A.wav", "b.wav", "c.wav"]
    end

    test "a file on disk whose name the gate would refuse is not listed" do
      # The directory is on disk, so a name can arrive there without passing the
      # gate — a copy, a hand-edit, a restore from before the gate existed.
      # Listing one would report a source no entry point would accept.
      dir = Path.join(System.tmp_dir!(), "bc_listin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "we?ird.wav.x"), "")
      File.write!(Path.join(dir, "fine.wav.x"), "")

      assert SourceName.list_in(dir, ".x") == ["fine.wav"]
    end
  end
end
