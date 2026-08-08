defmodule BusterClaw.Notifications.Cutup.TranscriptsTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Cutup.Transcripts
  alias BusterClaw.Telephony

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, tmp_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :library_root, previous)
      else
        Application.delete_env(:buster_claw, :library_root)
      end
    end)

    :ok
  end

  # A voicemail with its audio actually written to disk — the default shape,
  # since `with_recording: true` is the default and an event without a real file
  # is invisible to `search/2`.
  defp voicemail(tmp_dir, attrs) do
    attrs =
      case Map.fetch(attrs, :recording_path) do
        {:ok, _explicit} -> attrs
        :error -> Map.put(attrs, :recording_path, recording!(tmp_dir))
      end

    record!(attrs)
  end

  defp record!(attrs) do
    n = System.unique_integer([:positive])

    {:ok, event} =
      Telephony.record_event(
        Map.merge(
          %{
            direction: "inbound",
            kind: "voicemail",
            from_number: "+15035551234",
            to_number: "+18446878016",
            twilio_sid: "RE#{n}",
            duration_seconds: 10,
            occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        ),
        observe: false
      )

    event
  end

  defp recording!(tmp_dir) do
    relative = Path.join("phone/recordings", "vm-#{System.unique_integer([:positive])}.mp3")
    absolute = Path.join(tmp_dir, relative)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "mp3-bytes")
    relative
  end

  describe "search/2 matching" do
    test "matches whole words and not substrings", %{tmp_dir: tmp_dir} do
      hit = voicemail(tmp_dir, %{transcript: "Meet me at the harbor at dawn."})
      _near_miss = voicemail(tmp_dir, %{transcript: "She harbored a grudge for years."})

      assert [%{event_id: id}] = Transcripts.search("harbor")
      assert id == hit.id
    end

    test "whole_word: false reaches the substring", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "Meet me at the harbor at dawn."})
      voicemail(tmp_dir, %{transcript: "She harbored a grudge for years."})

      assert length(Transcripts.search("harbor", whole_word: false)) == 2
    end

    test "is case-insensitive both ways", %{tmp_dir: tmp_dir} do
      event = voicemail(tmp_dir, %{transcript: "The HARBOR is closed."})

      assert [%{event_id: id}] = Transcripts.search("harbor")
      assert id == event.id
      assert [%{event_id: ^id}] = Transcripts.search("HaRbOr")
    end

    test "an apostrophe word is one word", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "Good morning, it's six o'clock."})

      assert [_hit] = Transcripts.search("o'clock")
      assert Transcripts.search("clock") == []
    end

    test "a multi-word query matches across punctuation", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "Okay -- call, me back when you can."})

      assert [_hit] = Transcripts.search("call me back")
    end

    test "match_count counts every occurrence", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{
        transcript: "Harbor. The harbor is by the other harbor, near the harbormaster."
      })

      assert [%{match_count: 3}] = Transcripts.search("harbor")
    end

    test "events with no transcript are skipped", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: nil})
      voicemail(tmp_dir, %{transcript: ""})
      kept = voicemail(tmp_dir, %{transcript: "harbor"})

      assert [%{event_id: id}] = Transcripts.search("harbor")
      assert id == kept.id
    end

    test "an empty, blank or punctuation-only query returns []", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "Meet me at the harbor."})

      assert Transcripts.search("") == []
      assert Transcripts.search("   ") == []
      assert Transcripts.search("???") == []
      assert Transcripts.search("-- ... --") == []
      assert Transcripts.search(nil) == []
    end

    test "no matching rows returns []" do
      assert Transcripts.search("harbor") == []
      assert Transcripts.search("harbor", with_recording: false) == []
    end
  end

  describe "search/2 scoping" do
    test "with_recording: true drops a nil recording_path", %{tmp_dir: tmp_dir} do
      no_audio = record!(%{transcript: "harbor lights", recording_path: nil})
      with_audio = voicemail(tmp_dir, %{transcript: "harbor lights"})

      assert [%{event_id: id}] = Transcripts.search("harbor")
      assert id == with_audio.id

      ids = Transcripts.search("harbor", with_recording: false) |> Enum.map(& &1.event_id)
      assert Enum.sort(ids) == Enum.sort([no_audio.id, with_audio.id])
    end

    test "with_recording: true drops a path whose file is not on disk", %{tmp_dir: tmp_dir} do
      ghost = record!(%{transcript: "harbor lights", recording_path: "phone/recordings/gone.mp3"})
      real = voicemail(tmp_dir, %{transcript: "harbor lights"})

      assert [%{event_id: id}] = Transcripts.search("harbor")
      assert id == real.id

      assert ghost.id in (Transcripts.search("harbor", with_recording: false)
                          |> Enum.map(& &1.event_id))
    end

    test "recording_path comes back exactly as stored, relative to the Library root", %{
      tmp_dir: tmp_dir
    } do
      relative = recording!(tmp_dir)
      voicemail(tmp_dir, %{transcript: "harbor", recording_path: relative})

      assert [%{recording_path: ^relative}] = Transcripts.search("harbor")
      refute String.starts_with?(relative, "/")
      assert File.regular?(Path.join(tmp_dir, relative))
    end

    test ":kind, :since and :limit scope the results", %{tmp_dir: tmp_dir} do
      old = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)
      recent = DateTime.utc_now() |> DateTime.truncate(:second)
      cutoff = DateTime.add(recent, -1, :day)

      voicemail(tmp_dir, %{transcript: "harbor one", occurred_at: old})
      voicemail(tmp_dir, %{transcript: "harbor two", occurred_at: recent})
      voicemail(tmp_dir, %{transcript: "harbor three", kind: "call", occurred_at: recent})

      assert length(Transcripts.search("harbor")) == 2
      assert length(Transcripts.search("harbor", since: cutoff)) == 1
      assert length(Transcripts.search("harbor", kind: "call")) == 1
      assert length(Transcripts.search("harbor", kind: :any)) == 3
      assert length(Transcripts.search("harbor", kind: :any, limit: 2)) == 2
    end

    test "hits carry the event's identifying fields, newest first", %{tmp_dir: tmp_dir} do
      earlier = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      later = DateTime.utc_now() |> DateTime.truncate(:second)

      voicemail(tmp_dir, %{
        transcript: "harbor",
        occurred_at: earlier,
        from_number: "+15030000001"
      })

      voicemail(tmp_dir, %{transcript: "harbor", occurred_at: later, from_number: "+15030000002"})

      assert [newest, oldest] = Transcripts.search("harbor")
      assert newest.from_number == "+15030000002"
      assert newest.occurred_at == later
      assert oldest.from_number == "+15030000001"
      assert is_integer(newest.event_id)
    end
  end

  describe "excerpt" do
    test "contains the match with surrounding context", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "Meet me down at the harbor at dawn tomorrow."})

      assert [%{excerpt: excerpt}] = Transcripts.search("harbor")
      assert excerpt =~ "harbor"
      assert excerpt =~ "at dawn"
    end

    test "is bounded, elided on both sides, and single-spaced", %{tmp_dir: tmp_dir} do
      filler = String.duplicate("padding words here ", 60)
      voicemail(tmp_dir, %{transcript: filler <> "\n harbor \n" <> filler})

      assert [%{excerpt: excerpt}] = Transcripts.search("harbor")
      assert excerpt =~ "harbor"
      assert String.length(excerpt) <= 240
      assert String.starts_with?(excerpt, "…")
      assert String.ends_with?(excerpt, "…")
      refute excerpt =~ "\n"
      refute excerpt =~ "  "
    end

    test "a short transcript is its own excerpt, unelided", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "Harbor."})

      assert [%{excerpt: "Harbor."}] = Transcripts.search("harbor")
    end
  end

  describe "vocabulary/1 and top_words/1" do
    test "counts words across every event", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "The harbor at dawn."})
      voicemail(tmp_dir, %{transcript: "Harbor, harbor -- the boats."})

      vocabulary = Transcripts.vocabulary()

      assert vocabulary["harbor"] == 3
      assert vocabulary["the"] == 2
      assert vocabulary["dawn"] == 1
      refute Map.has_key?(vocabulary, "")
    end

    test "min_count is the 'do I have enough takes' filter", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "harbor harbor dawn"})

      assert Transcripts.vocabulary(min_count: 2) == %{"harbor" => 2}
    end

    test "only counts events with audio on disk unless told otherwise", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "harbor"})
      record!(%{transcript: "harbor harbor", recording_path: nil})

      assert Transcripts.vocabulary() == %{"harbor" => 1}
      assert Transcripts.vocabulary(with_recording: false) == %{"harbor" => 3}
    end

    test "an empty corpus is an empty map" do
      assert Transcripts.vocabulary() == %{}
      assert Transcripts.top_words() == []
    end

    test "top_words sorts by count then alphabetically", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "harbor harbor harbor boats boats anchor"})

      assert Transcripts.top_words(limit: 3) == [{"harbor", 3}, {"boats", 2}, {"anchor", 1}]
    end
  end

  describe "coverage/1" do
    test "summarizes the corpus", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "The harbor at dawn.", duration_seconds: 12})
      record!(%{transcript: "no audio here", recording_path: nil, duration_seconds: 5})
      record!(%{transcript: "gone", recording_path: "phone/recordings/gone.mp3"})
      voicemail(tmp_dir, %{transcript: nil, duration_seconds: 7})

      assert %{
               kind: "voicemail",
               events: 4,
               with_transcript: 3,
               with_recording_path: 3,
               recordings_on_disk: 2,
               missing_audio: 1,
               usable: 1,
               duration_seconds: 12,
               words: 4,
               distinct_words: 4
             } = Transcripts.coverage()
    end

    test "is all zeroes on an empty database" do
      assert %{events: 0, usable: 0, duration_seconds: 0, words: 0, distinct_words: 0} =
               Transcripts.coverage()
    end

    test "does not raise when the Library root is unconfigured", %{tmp_dir: tmp_dir} do
      voicemail(tmp_dir, %{transcript: "harbor"})
      Application.delete_env(:buster_claw, :library_root)

      assert %{recordings_on_disk: 0, usable: 0} = Transcripts.coverage()
      assert Transcripts.search("harbor") == []
      assert [_hit] = Transcripts.search("harbor", with_recording: false)
    end
  end

  describe "words/1" do
    test "normalizes and keeps internal apostrophes" do
      assert Transcripts.words("Good morning, it's 6 o'clock!") ==
               ~w(good morning it's 6 o'clock)
    end

    test "nil and non-binaries are empty" do
      assert Transcripts.words(nil) == []
      assert Transcripts.words(:harbor) == []
      assert Transcripts.words("") == []
    end
  end
end
