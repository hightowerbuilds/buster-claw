defmodule BusterClawWeb.VoiceLibraryTest do
  @moduledoc """
  The Studio's **Voice Library** — browsing words, hearing takes, building a
  sentence, and recording into a voice bank (`STUDIO_ROADMAP` Parts V and VI).

  What is NOT tested here, stated so a later reader does not mistake green for
  covered: **no test in this file opens a microphone.** `getUserMedia` cannot be
  driven from `Phoenix.LiveViewTest`, so the capture path is exercised only
  through the capability event the hook pushes back. The one thing that would
  actually prove capture works is V.4a — a person clicking a permission dialog on
  a packaged build — and it has never been run.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications.Capture.Take
  alias BusterClaw.Notifications.Cutup.Bank
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Sentence
  alias BusterClaw.Notifications.Cutup.Takes
  alias BusterClaw.Notifications.SoundStudio

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "bc_contrib_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    BusterClaw.Settings.mark_onboarding_complete()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, conn: conn, root: root}
  end

  defp open_library(conn) do
    # /studio since 08-16 — was a Home sub-tab click.
    {:ok, view, _html} = live(conn, ~p"/studio")
    render_click(element(view, "[phx-click='select_studio_tab'][phx-value-tab='voice']"))
    view
  end

  defp section(view, key) do
    render_click(element(view, "[phx-click='voice_section'][phx-value-section='#{key}']"))
    view
  end

  defp recording(conn) do
    view = conn |> open_library() |> section("record")
    render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
    view
  end

  describe "the surface" do
    test "renders the recorder and the bank selector", %{conn: conn} do
      view = recording(conn)

      assert has_element?(view, "#studio-voice")
      assert has_element?(view, "#studio-recorder")
      assert has_element?(view, "[data-studio-tab='voice']")
    end

    test "the record button is disabled before a word is typed", %{conn: conn} do
      view = recording(conn)

      assert has_element?(view, "#studio-recorder-status[data-armed='false']")
    end

    test "the default bank is offered with no configuration", %{conn: conn} do
      view = recording(conn)

      assert has_element?(view, "option[value='voicemail']")
    end
  end

  describe "the capability gate" do
    # The server does not claim to know whether capture works — V.4a has never
    # run. It renders what the browser reported.
    test "starts by saying it is still checking", %{conn: conn} do
      view = conn |> open_library() |> section("record")

      assert render(view) =~ "Checking whether this app can open a microphone"
    end

    test "a denial names what stopped it, and stays un-armed", %{conn: conn} do
      view = recording(conn)

      render_hook(view, "contribute", %{
        "do" => "capability",
        "state" => "denied",
        "detail" => "NotAllowedError"
      })

      html = render(view)
      assert html =~ "NotAllowedError"
      assert html =~ "has not been granted microphone access yet"
      assert has_element?(view, "#studio-recorder-status[data-armed='false']")
    end

    test "a host with no microphone API says so without blaming the app", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "unsupported"})

      assert render(view) =~ "no microphone API at all"
    end

    test "a forged capability value degrades to unproven rather than arming", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready-ish"})

      assert render(view) =~ "Checking whether this app can open a microphone"
      assert has_element?(view, "#studio-recorder-status[data-armed='false']")
    end
  end

  describe "arming" do
    # Both halves are required: a granted microphone with no word has nothing to
    # file the take under, and a word with no microphone has nothing to record.
    test "needs BOTH a granted microphone and a word", %{conn: conn} do
      view = recording(conn)

      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      assert has_element?(view, "#studio-recorder-status[data-armed='false']")

      render_hook(view, "contribute", %{"do" => "word", "word" => "harbor"})
      assert has_element?(view, "#studio-recorder-status[data-armed='true']")
      assert render(view) =~ "say “harbor”"
    end

    test "a whitespace-only word does not arm it", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      render_hook(view, "contribute", %{"do" => "word", "word" => "   "})

      assert has_element?(view, "#studio-recorder-status[data-armed='false']")
    end
  end

  describe "banks" do
    test "a new bank can be created and selected", %{conn: conn} do
      view = recording(conn)

      render_submit(element(view, "form:has(input[value='bank_create'])"), %{
        "do" => "bank_create",
        "name" => "Aunt Mary"
      })

      assert render(view) =~ "Created aunt-mary"
      assert has_element?(view, "option[value='aunt-mary']")

      render_hook(view, "contribute", %{"do" => "bank_select", "name" => "aunt-mary"})
      assert Bank.active() == "aunt-mary"
    end

    test "an unusable name is refused with the rule, not a stack trace", %{conn: conn} do
      view = recording(conn)

      render_submit(element(view, "form:has(input[value='bank_create'])"), %{
        "do" => "bank_create",
        "name" => "../../etc"
      })

      assert render(view) =~ "lowercase letters, numbers and hyphens"
      refute Enum.any?(Bank.list(), &String.contains?(&1.name, "/"))
    end

    test "selecting an unknown bank leaves the active one alone", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "bank_select", "name" => "nobody"})

      assert Bank.active() == "voicemail"
      assert render(view) =~ "could not be selected"
    end
  end

  describe "saving a take" do
    test "a take becomes a source and reports its peak", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      render_hook(view, "contribute", %{"do" => "word", "word" => "harbor"})

      render_hook(view, "contribute_take", %{"pcm" => tone(0.5), "sample_rate" => 48_000})

      html = render(view)
      assert html =~ "Saved harbor.wav"
      assert html =~ "dBFS"
    end

    test "a clipped take is refused with the reason, and nothing is stored", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      render_hook(view, "contribute", %{"do" => "word", "word" => "harbor"})

      render_hook(view, "contribute_take", %{"pcm" => tone(1.0), "sample_rate" => 48_000})

      assert render(view) =~ "clipped"
      assert SoundStudio.list() == []
    end

    test "a silent take is refused as a muted device, not stored as a quiet one",
         %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      render_hook(view, "contribute", %{"do" => "word", "word" => "harbor"})

      render_hook(view, "contribute_take", %{"pcm" => tone(0.0), "sample_rate" => 48_000})

      assert render(view) =~ "silent"
      assert SoundStudio.list() == []
    end

    test "the new word appears in the Voice tab's vocabulary immediately", %{conn: conn} do
      view = recording(conn)
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      render_hook(view, "contribute", %{"do" => "word", "word" => "harbor"})
      render_hook(view, "contribute_take", %{"pcm" => tone(0.5), "sample_rate" => 48_000})

      section(view, "words")

      assert render(view) =~ "harbor"
    end

    test "a take lands in the ACTIVE bank and the dictionary follows the switch",
         %{conn: conn} do
      view = recording(conn)

      render_submit(element(view, "form:has(input[value='bank_create'])"), %{
        "do" => "bank_create",
        "name" => "luke"
      })

      render_hook(view, "contribute", %{"do" => "bank_select", "name" => "luke"})
      render_hook(view, "contribute", %{"do" => "capability", "state" => "ready"})
      render_hook(view, "contribute", %{"do" => "word", "word" => "harbor"})
      render_hook(view, "contribute_take", %{"pcm" => tone(0.5), "sample_rate" => 48_000})

      {:ok, index} = Index.load("harbor.wav")
      assert index.bank == "luke"

      # And the dictionary reports the bank it is pointed at, not the machine:
      # switching back to a bank with no takes must show an empty vocabulary
      # rather than the word just recorded into a different voice.
      render_hook(view, "contribute", %{"do" => "bank_select", "name" => "voicemail"})
      section(view, "words")

      refute render(view) =~ "harbor"
    end
  end

  describe "hearing a word — VI.1's pane 2" do
    # The roadmap listed this as absent because it "needs a route serving a
    # take's audio". It does not: a take is a SLICE of a source, and
    # `/studio/file/:name` has served sources with byte ranges all along. What
    # the server owes the client is the source name and the two offsets.
    test "selecting a word offers each take with the slice needed to play it",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      seed("harbor", "harbor-two.wav")

      view = conn |> open_library() |> section("words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))

      assert render(view) =~ "Takes of"
      assert has_element?(view, "[data-play][data-source='harbor-one.wav'][data-end]")
      assert has_element?(view, "[data-play][data-source='harbor-two.wav'][data-end]")
    end

    test "a word with one take says so where it cannot be missed", %{conn: conn} do
      seed("harbor", "harbor-one.wav")

      view = conn |> open_library() |> section("words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))

      assert render(view) =~ "splicing it is not a cut-up"
    end

    test "takes come from the ACTIVE bank only — another voice is not an alternative",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      {:ok, _} = Bank.create("luke")

      view = conn |> open_library() |> section("words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      assert has_element?(view, "[data-play][data-source='harbor-one.wav']")

      # Switching voice must not leave another bank's takes on screen.
      render_hook(view, "contribute", %{"do" => "bank_select", "name" => "luke"})
      section(view, "words")

      refute has_element?(view, "[data-play][data-source='harbor-one.wav']")
    end
  end

  describe "building a sentence" do
    test "a phrase whose words all exist builds a playable file", %{conn: conn} do
      seed("hello", "hello.wav")
      seed("harbor", "harbor.wav")

      view = conn |> open_library() |> section("sentence")
      build(view, "hello harbor")

      assert has_element?(view, "[data-play][data-source='voice-preview.wav']")
      assert SoundStudio.path_for("voice-preview.wav")
    end

    test "a missing word is named, and the button is refused BEFORE a splice is spent",
         %{conn: conn} do
      seed("hello", "hello.wav")

      view = conn |> open_library() |> section("sentence")

      render_change(element(view, "form[phx-change='voice_sentence']"), %{
        "sentence" => "hello zebra"
      })

      # The chip already knows, so the build is refused without attempting it.
      assert has_element?(view, "[phx-click='voice_preview'][disabled]")

      # And if it is reached anyway (Enter on the form), the refusal names the word.
      render_submit(element(view, "form[phx-change='voice_sentence']"), %{
        "sentence" => "hello zebra"
      })

      assert render(view) =~ "no take of zebra"
    end

    test "rebuilding bumps the version, so the client cannot replay the old audio",
         %{conn: conn} do
      seed("hello", "hello.wav")
      seed("harbor", "harbor.wav")

      view = conn |> open_library() |> section("sentence")

      build(view, "hello harbor")
      assert has_element?(view, "[data-play][data-version='1']")

      build(view, "harbor hello")
      assert has_element?(view, "[data-play][data-version='2']")
    end
  end

  describe "recording a whole sentence" do
    # V.8's donor session in miniature, and the reason it earns its own path:
    # reading a line is far faster than saying single words, at the cost of every
    # interior boundary being an estimate rather than a measurement.
    test "finds each word inside one take, and labels the timings as aligned",
         %{conn: conn} do
      view = recording(conn)
      record(view, "the harbor is quiet tonight")

      {:ok, index} = Index.load("the-harbor-is-quiet.wav")

      assert index.origin == :aligned
      assert Enum.map(index.words, & &1.word) == ~w(the harbor is quiet tonight)

      # A guess must never inherit a measurement's confidence.
      assert Enum.all?(index.words, &(&1.confidence < 1.0))
    end

    test "one word alone is :manual; the same word inside a sentence is not",
         %{conn: conn} do
      view = recording(conn)
      record(view, "harbor")
      record(view, "the harbor is quiet")

      assert {:ok, %{origin: :manual}} = Index.load("harbor.wav")

      assert {:ok, %{origin: :aligned}} =
               Index.load("the-harbor-is-quiet.wav")
    end
  end

  describe "multiple takes of one word" do
    # The recorder could capture each word exactly once until 08-16, because a
    # derived name collided and the collision was refused. Refusing a name the
    # OPERATOR chose is still right; refusing one derived from the word was not.
    test "recording the same word twice keeps both, numbered", %{conn: conn} do
      view = recording(conn)
      record(view, "harbor")
      record(view, "harbor")
      record(view, "harbor")

      assert "harbor.wav" in SoundStudio.list()
      assert "harbor-2.wav" in SoundStudio.list()
      assert "harbor-3.wav" in SoundStudio.list()

      # Nothing was overwritten — three files, three indexes, three takes.
      assert length(Takes.list("voicemail", "harbor")) == 3
    end

    test "a name the operator typed still refuses to collide", %{conn: conn} do
      _view = recording(conn)
      {:ok, take} = Take.decode(tone(0.5), 48_000)

      assert {:ok, "chosen.wav"} = Take.store(take, "chosen", "harbor")
      assert {:error, :name_taken} = Take.store(take, "chosen", "harbor")
    end

    test "the word stops being quote-only once it has a second take", %{conn: conn} do
      view = recording(conn)
      record(view, "harbor")

      view = section(view, "words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      assert render(view) =~ "splicing it is not a cut-up"

      section(view, "record")
      record(view, "harbor")

      view = section(view, "words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      refute render(view) =~ "splicing it is not a cut-up"
    end
  end

  describe "choosing which take is used" do
    test "marking one narrows the splice to it, and unmarking hands it back",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      seed("harbor", "harbor-two.wav")

      view = conn |> open_library() |> section("words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))

      render_click(element(view, "[phx-click='voice_prefer'][phx-value-source='harbor-two.wav']"))
      assert Takes.preferred("voicemail", "harbor").source == "harbor-two.wav"

      # And it is what the splice actually uses — not merely what is stored.
      {:ok, built} = Sentence.build("harbor", bank: "voicemail")
      assert Enum.map(built.plan.cuts, & &1.source) == ["harbor-two.wav"]

      render_click(element(view, "[phx-click='voice_unprefer']"))
      assert Takes.preferred("voicemail", "harbor") == nil
    end

    test "a preference is per bank, so two voices do not share one choice",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      {:ok, _} = Bank.create("luke")

      view = conn |> open_library() |> section("words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      render_click(element(view, "[phx-click='voice_prefer'][phx-value-source='harbor-one.wav']"))

      assert Takes.preferred("voicemail", "harbor")
      refute Takes.preferred("luke", "harbor")
    end

    test "a preference naming a deleted take costs a worse splice, never a refusal" do
      seed("harbor", "harbor-one.wav")
      seed("harbor", "harbor-two.wav")

      {:ok, _} = Takes.prefer("voicemail", "harbor", "harbor-two.wav", 0.0)
      {:ok, _} = Takes.delete("harbor-two.wav", 0.0)

      # The pointer is now dangling. Building must fall through to what exists.
      assert {:ok, built} = Sentence.build("harbor", bank: "voicemail")
      assert Enum.map(built.plan.cuts, & &1.source) == ["harbor-one.wav"]
    end

    test "preferring a take that does not exist is refused rather than stored" do
      seed("harbor", "harbor-one.wav")

      assert {:error, :no_such_take} =
               Takes.prefer("voicemail", "harbor", "nowhere.wav", 0.0)

      assert Takes.preferred("voicemail", "harbor") == nil
    end
  end

  describe "deleting a take" do
    test "a word recorded on its own takes its audio with it", %{conn: conn} do
      view = recording(conn)
      record(view, "harbor")

      view = section(view, "words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      render_click(element(view, "[phx-click='voice_delete'][phx-value-source='harbor.wav']"))

      assert render(view) =~ "Deleted that take"
      assert SoundStudio.list() == []
      assert {:error, :not_found} = Index.load("harbor.wav")
    end

    test "a word inside a SENTENCE loses the entry, and the recording stays",
         %{conn: conn} do
      view = recording(conn)
      record(view, "the harbor is quiet tonight")

      {:ok, before} = Index.load("the-harbor-is-quiet.wav")
      assert length(before.words) == 5

      view = section(view, "words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      render_click(element(view, "[phx-click='voice_delete']"))

      {:ok, after_delete} = Index.load("the-harbor-is-quiet.wav")
      assert length(after_delete.words) == 4
      refute "harbor" in Enum.map(after_delete.words, & &1.word)

      # The master survives — V.7's policy is that it is the only way back.
      assert "the-harbor-is-quiet.wav" in SoundStudio.list()
    end

    test "deleting the last take of a word removes it from the vocabulary",
         %{conn: conn} do
      view = recording(conn)
      record(view, "harbor")

      view = section(view, "words")
      assert render(view) =~ "harbor"

      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      render_click(element(view, "[phx-click='voice_delete'][phx-value-source='harbor.wav']"))

      refute has_element?(view, "[phx-click='voice_select'][phx-value-word='harbor']")
    end

    test "deleting one of several leaves the list open on the rest", %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      seed("harbor", "harbor-two.wav")

      view = conn |> open_library() |> section("words")
      render_click(element(view, "[phx-click='voice_select'][phx-value-word='harbor']"))
      render_click(element(view, "[phx-click='voice_delete'][phx-value-source='harbor-one.wav']"))

      # The selection survives — closing it would drop the operator out of the
      # list they are working in.
      assert has_element?(view, "[data-play][data-source='harbor-two.wav']")
      refute has_element?(view, "[data-play][data-source='harbor-one.wav']")
    end
  end

  describe "a sentence chip leads to the word" do
    test "clicking a word that exists opens Words, filtered, with its takes",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      seed("harbor", "harbor-two.wav")

      view = conn |> open_library() |> section("sentence")
      render_change(element(view, "form[phx-change='voice_sentence']"), %{"sentence" => "harbor"})

      render_click(element(view, "[phx-click='voice_open_word'][phx-value-word='harbor']"))

      # Landed in Words, with the word selected and BOTH takes listed.
      assert has_element?(
               view,
               "[phx-click='voice_section'][phx-value-section='words'][aria-current]"
             )

      assert render(view) =~ "Takes of"
      assert has_element?(view, "[data-play][data-source='harbor-one.wav']")
      assert has_element?(view, "[data-play][data-source='harbor-two.wav']")
    end

    test "the vocabulary list is narrowed to it, visibly rather than secretly",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")
      seed("hello", "hello.wav")

      view = conn |> open_library() |> section("sentence")
      render_change(element(view, "form[phx-change='voice_sentence']"), %{"sentence" => "harbor"})
      render_click(element(view, "[phx-click='voice_open_word'][phx-value-word='harbor']"))

      # The filter did the narrowing, and the box SHOWS it — the operator can
      # clear it. A highlighted row inside 237 others would not be "sent to the
      # word", and a hidden filter would be a mode they cannot escape.
      assert has_element?(view, "input[name='query'][value='harbor']")
      refute has_element?(view, "[phx-click='voice_select'][phx-value-word='hello']")
    end

    test "a chip is clickable for a quote-only word too — one take is still a take",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")

      view = conn |> open_library() |> section("sentence")
      render_change(element(view, "form[phx-change='voice_sentence']"), %{"sentence" => "harbor"})

      render_click(element(view, "[phx-click='voice_open_word'][phx-value-word='harbor']"))

      assert has_element?(view, "[data-play][data-source='harbor-one.wav']")
    end

    test "a MISSING word arms the recorder for it instead — the only thing that helps",
         %{conn: conn} do
      view = recording(conn)
      view = section(view, "sentence")
      render_change(element(view, "form[phx-change='voice_sentence']"), %{"sentence" => "zebra"})

      # It must not lead to Words: there is nothing there to show.
      refute has_element?(view, "[phx-click='voice_open_word'][phx-value-word='zebra']")

      render_click(element(view, "[phx-click='voice_record_word'][phx-value-word='zebra']"))

      assert has_element?(view, "#studio-recorder")
      assert has_element?(view, "input[name='word'][value='zebra']")
      assert render(view) =~ "say “zebra”"
    end

    test "the chip carries the NORMALISED word, so punctuation does not miss",
         %{conn: conn} do
      seed("harbor", "harbor-one.wav")

      view = conn |> open_library() |> section("sentence")

      render_change(element(view, "form[phx-change='voice_sentence']"), %{"sentence" => "Harbor!"})

      # Rendered as typed, addressed as stored — the corpus is keyed on the
      # normalised form and the chip has to click through to it.
      render_click(element(view, "[phx-click='voice_open_word'][phx-value-word='harbor']"))

      assert has_element?(view, "[data-play][data-source='harbor-one.wav']")
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The PCM path end to end, minus the microphone: the hook's payload shape goes
  # in, a source and an index come out.
  defp tone(amplitude, samples \\ 4800) do
    0..(samples - 1)
    |> Enum.map(fn i -> amplitude * :math.sin(2 * :math.pi() * 440 * i / 48_000) end)
    |> encode()
  end

  # Bursts separated by silence — what N spoken words actually look like to VAD.
  #
  # A CONSTANT tone will not do, and finding that out was worth the detour: it
  # has no dynamic range, so the noise-floor estimate lands on the signal itself
  # and `Vad.spans/2` returns []. Alignment then has nothing to divide and the
  # index is empty. The failure is silent and looks exactly like a broken
  # aligner, so the fixture has to be speech-SHAPED, not merely audible.
  defp speech(words, amplitude \\ 0.5) do
    for burst <- 0..(words - 1), i <- 0..9_599 do
      if i < 6_000,
        do: amplitude * :math.sin(2 * :math.pi() * (200 + burst * 40) * i / 48_000),
        else: 0.0
    end
    |> encode()
  end

  defp encode(floats) do
    floats |> Enum.reduce(<<>>, fn f, acc -> acc <> <<f::little-float-32>> end) |> Base.encode64()
  end

  # Two takes of one word need two source names, and the recorder names a file
  # from its text — deliberately, since a recording is never overwritten. So the
  # corpus is seeded through the domain, which is also what an import would do.
  defp seed(word, name) do
    {:ok, take} = Take.decode(tone(0.5), 48_000)
    {:ok, ^name} = Take.store(take, name, word)
    name
  end

  # A single word records as a plain tone; a sentence needs speech-shaped audio
  # so the aligner has spans to divide. See `speech/2`.
  defp record(view, text) do
    words = text |> String.split(~r/\s+/u, trim: true) |> length()
    pcm = if words > 1, do: speech(words), else: tone(0.5)

    render_hook(view, "contribute", %{"do" => "word", "word" => text})
    render_hook(view, "contribute_take", %{"pcm" => pcm, "sample_rate" => 48_000})
    view
  end

  defp build(view, phrase) do
    render_change(element(view, "form[phx-change='voice_sentence']"), %{"sentence" => phrase})
    render_click(element(view, "[phx-click='voice_preview']"))
    view
  end
end
