defmodule BusterClawWeb.Status.Voice do
  @moduledoc """
  State for the Studio's **Voice** sub-tab — the Ramshackle surface
  (`STUDIO_ROADMAP` VI.1).

  Socket-in / socket-out functions, and the assigns live in `StatusLive` for the
  reason every home panel's state does: the panel renders behind `:if`, so
  anything the component held is discarded on a tab switch. A half-typed
  sentence that empties when you glance at Chat reads as the feature being
  broken, not as a tab switch — the same argument `Status.Studio` makes for the
  undo stack.

  A sibling of `Status.Studio` rather than part of it: that module is the
  arranger's state and is near its cap, and these two share nothing but the tab
  they sit under.

  ## What this half does, and what it deliberately does not

  Two of VI.1's three panes, and **neither needs a microphone** — which is the
  whole reason this can exist before Part V's recorder does. The corpus is
  already there: ten sources, 237 distinct words, 655 takes, every one of them
  `aligned`.

    * **Vocabulary** — every indexed word by take count, with the single-take
      ones marked. *A word with one take is a quotation, not a cut-up*, and that
      distinction is the most useful thing this surface can show.
    * **Sentence check** — type a phrase, see per word whether the corpus can cut
      it, only quote it, or not say it at all.

  **Pane 2 (takes, waveform, audition) is not here.** It needs a route that
  serves a take's audio, which is a real surface of its own; browsing without
  hearing is still worth shipping, and the roadmap says so.

  ## Two decisions worth not re-deriving

  **The report is loaded lazily and cached in the socket.** `Gaps.report/1` reads
  every index file on every call — deliberately, so a report is a fresh
  measurement rather than a stale cache. That is right for a command and wrong
  for a keystroke, so the tab loads once on first open and offers a refresh.

  **The sentence check does not call `Gaps.report/1` again.** It looks each word
  up in the report already loaded, normalising through
  `Cutup.Index.normalize_word/1` — the same function the corpus is keyed on. Two
  reasons: a second read per keystroke would be absurd, and re-implementing the
  normalisation here would put a second definition of "what counts as a word"
  in the tree, which is the drift this codebase keeps finding.
  """
  import Phoenix.Component

  alias BusterClaw.Notifications.Cutup.Bank
  alias BusterClaw.Notifications.Cutup.Gaps
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Sentence
  alias BusterClaw.Notifications.Cutup.Takes
  alias BusterClaw.Notifications.SoundStudio

  @doc """
  Mount defaults. Nothing is read from disk here — the corpus load waits until
  the tab is actually opened, so a homepage mount never pays for a surface the
  operator may not visit.
  """
  def assign_voice(socket) do
    socket
    |> assign(:voice_report, nil)
    |> assign(:voice_error, nil)
    |> assign(:voice_query, "")
    |> assign(:voice_sentence, "")
    |> assign(:voice_section, "words")
    |> assign(:voice_selected, nil)
    |> assign(:voice_takes, [])
    |> assign(:voice_preview, nil)
    |> assign(:voice_preview_error, nil)
    |> assign(:voice_notice, nil)
  end

  @doc """
  Switch the Library's main pane. Refuses a section the sidebar never offered.

  Same posture as `Status.Studio.select_studio_tab/2`: a forged value is a no-op
  rather than a crash, and the whitelist is one literal so the sidebar and this
  cannot disagree.
  """
  @sections ~w(words sentence record)

  def sections, do: @sections

  def put_section(socket, section) when section in @sections,
    do: assign(socket, :voice_section, section)

  def put_section(socket, _section), do: socket

  @doc """
  Select a word and load its takes, so the main pane can list and play them.

  This is VI.1's **Pane 2** — the one the roadmap listed as missing because it
  "needs a route serving a take's audio". That route turned out to exist:
  `/studio/file/:name` already serves any studio source with byte ranges, so a
  take is a slice of a file the browser can already fetch. What was missing was
  never the route; it was somebody checking.

  Takes are read from the ACTIVE bank only. A take of the same word in another
  voice is not an alternative — it is a different instrument.
  """
  def select_word(socket, word) when is_binary(word) do
    socket
    |> assign(:voice_selected, word)
    |> assign(:voice_takes, Takes.list(Bank.active(), word))
  end

  def select_word(socket, _word), do: socket

  @doc """
  Jump from a sentence chip to the word it grades: Words, filtered to that word,
  with its takes open.

  The filter is set as well as the selection, and that is the point rather than a
  side effect. A vocabulary of 237 words is a long list; highlighting a row
  somewhere inside it is not "sent to the word", it is "sent to the list". The
  filter box shows what it was set to, so the narrowing is visible state the
  operator can clear, not a hidden mode they have to escape.
  """
  def open_word(socket, word) when is_binary(word) do
    socket
    |> put_section("words")
    |> assign(:voice_query, word)
    |> select_word(word)
  end

  def open_word(socket, _word), do: socket

  @doc """
  Choose which take of the selected word gets spliced, or clear the choice.

  A preference is a pointer applied at selection time, not a score written onto
  the take — `Cutup.Takes` has the argument, and the short version is that
  editing `confidence` to express a preference makes the origin field lie.
  """
  def prefer_take(socket, source, start_ms) do
    with word when is_binary(word) <- socket.assigns.voice_selected,
         {start_ms, _rest} <- Float.parse(to_string(start_ms)),
         {:ok, _ref} <- Takes.prefer(Bank.active(), word, source, start_ms) do
      refresh_takes(socket, word)
    else
      _other -> socket
    end
  end

  def unprefer_take(socket) do
    case socket.assigns.voice_selected do
      word when is_binary(word) ->
        Takes.unprefer(Bank.active(), word)
        refresh_takes(socket, word)

      _none ->
        socket
    end
  end

  @doc """
  Delete one take of the selected word.

  What goes with it depends on what is left in the source — see
  `Cutup.Takes.delete/2`. The corpus report is reloaded because a word can leave
  the vocabulary entirely this way, and the Words list must not keep offering it.
  """
  def delete_take(socket, source, start_ms) do
    with word when is_binary(word) <- socket.assigns.voice_selected,
         {start_ms, _rest} <- Float.parse(to_string(start_ms)),
         {:ok, removed} <- Takes.delete(source, start_ms) do
      socket
      |> assign(:voice_notice, {:ok, deleted_message(source, removed)})
      |> refresh_takes(word)
      |> load_report()
    else
      {:error, reason} -> assign(socket, :voice_notice, {:error, delete_error(reason)})
      _other -> socket
    end
  end

  # The selection survives a delete, and empties only when its last take does —
  # otherwise removing one of four takes would close the list the operator is
  # working in.
  defp refresh_takes(socket, word) do
    case Takes.list(Bank.active(), word) do
      [] -> socket |> assign(:voice_selected, nil) |> assign(:voice_takes, [])
      takes -> assign(socket, :voice_takes, takes)
    end
  end

  defp deleted_message(source, %{audio: true}),
    do: "Deleted that take, and #{source} with it — it held nothing else."

  defp deleted_message(source, %{index: true}),
    do: "Deleted that take. #{source} has no words left, but the recording stays in the Studio."

  defp deleted_message(_source, _removed), do: "Deleted that take."

  defp delete_error(:no_such_take), do: "That take is already gone."
  defp delete_error(reason), do: "That take could not be deleted: #{inspect(reason)}."

  @doc """
  Forget the selected word, its takes, and any built preview.

  Called when the bank changes. Without it, switching voice leaves the previous
  voice's takes on screen and playable — which is the one confusion the whole
  partition exists to prevent, arriving through the back door of stale state.
  The built preview goes too: it was spliced from a voice that is no longer
  selected, so playing it would misattribute a sentence.
  """
  def clear_selection(socket) do
    socket
    |> assign(:voice_selected, nil)
    |> assign(:voice_takes, [])
    |> assign(:voice_preview, nil)
    |> assign(:voice_preview_error, nil)
    |> assign(:voice_notice, nil)
  end

  @doc """
  Build the current phrase into a playable file, or say why it cannot be built.

  Goes through `Cutup.Sentence`, the same code `sound_sentence` uses, so what the
  operator hears is what an agent would produce — see that module on why a second
  builder in the web layer would have drifted on exactly the details that decide
  whether a splice sounds right.

  The preview is written under a **fixed name** and overwritten every time. A
  sentence preview is scratch: it is not a take, it is not part of the corpus,
  and accumulating `preview-1.wav … preview-40.wav` in the studio's source list
  would turn a working surface into a junk drawer within an afternoon.
  """
  @preview_name "voice-preview.wav"

  def build_preview(socket) do
    phrase = socket.assigns.voice_sentence

    case Sentence.build(phrase, bank: Bank.active(), assemble: []) do
      {:ok, built} ->
        path = Path.join(SoundStudio.dir(), @preview_name)
        File.mkdir_p(SoundStudio.dir())

        case SoundStudio.write(built.clip, path) do
          :ok ->
            socket
            |> assign(:voice_preview, %{
              name: @preview_name,
              phrase: phrase,
              version: version(socket)
            })
            |> assign(:voice_preview_error, nil)

          {:error, reason} ->
            preview_error(socket, reason)
        end

      {:error, reason} ->
        preview_error(socket, reason)
    end
  end

  # NOT `:voice_error` — that assign means "the corpus could not be read" and the
  # surface renders it as such. A phrase that cannot be built is a different
  # thing entirely (usually a missing word, which is actionable), and routing it
  # through the corpus error would tell the operator their library is broken.
  # A monotonic counter, not a timestamp: the preview file keeps ONE name and is
  # overwritten on every build, so the client needs something that changes to
  # know its cached copy is stale. Without it the audition hook replays the
  # previous sentence from the same URL — real audio of a real phrase, and
  # therefore convincing.
  defp version(socket) do
    case socket.assigns.voice_preview do
      %{version: n} when is_integer(n) -> n + 1
      _none -> 1
    end
  end

  defp preview_error(socket, reason),
    do: socket |> assign(:voice_preview, nil) |> assign(:voice_preview_error, reason)

  @doc """
  Load the corpus report unless it is already in hand.

  Called when the Studio's sub-tab becomes `voice`. Idempotent, so switching
  away and back does not re-read ten files.
  """
  def ensure_report(%{assigns: %{voice_report: %{}}} = socket), do: socket
  def ensure_report(socket), do: load_report(socket)

  @doc """
  Re-read the corpus from disk, discarding what was cached.

  **Scoped to the active bank**, which is what makes the dictionary answer *"what
  can this voice say?"* rather than *"what is on this machine?"* — the second is
  not a question anyone can act on, because a phrase can only be spliced from one
  voice (`Cutup.Bank`). A word another bank has thirty takes of is still missing
  here, and saying so is the point.

  `Status.Contribute` calls this whenever the bank changes or a take lands, so
  the two tabs never disagree about whose corpus is on screen.
  """
  def load_report(socket) do
    case Gaps.report(bank: Bank.active()) do
      {:ok, report} ->
        socket
        |> assign(:voice_report, report)
        |> assign(:voice_error, nil)

      {:error, reason} ->
        socket
        |> assign(:voice_report, nil)
        |> assign(:voice_error, reason)
    end
  end

  @doc "Filter the vocabulary list. Empty shows everything."
  def put_query(socket, query) when is_binary(query),
    do: assign(socket, :voice_query, String.trim_leading(query))

  def put_query(socket, _query), do: socket

  @doc "The phrase being checked against the corpus."
  def put_sentence(socket, text) when is_binary(text),
    do: assign(socket, :voice_sentence, text)

  def put_sentence(socket, _text), do: socket

  # ---------------------------------------------------------------------------
  # Readers — pure over what is already assigned
  # ---------------------------------------------------------------------------

  @doc """
  The vocabulary rows to render: `{word, takes}` sorted by take count desc, then
  word asc, narrowed by the current query.

  The query matches on the normalised word, because that is what the corpus is
  keyed on — searching for `don't` finds `dont`, which is the entry that exists.
  """
  def vocabulary(%{voice_report: nil}, _query), do: []

  def vocabulary(%{voice_report: report}, query) do
    case normalize(query) do
      "" -> report.by_take_count
      term -> Enum.filter(report.by_take_count, fn {word, _n} -> String.contains?(word, term) end)
    end
  end

  @doc """
  Per-word verdict for the phrase being checked.

  Returns `[%{text:, word:, takes:, verdict:}]` in the order typed, where
  `verdict` is:

    * `:cuttable` — two or more takes, so a real choice was made when splicing.
    * `:quotable` — exactly one take. It can be spliced, but the result is the
      speaker saying that word the one way they happened to say it. Not a
      cut-up, and the surface says so.
    * `:missing` — no take at all. Only a recording can fix this, which is what
      makes this list the donor passage.

  Tokens that normalise to nothing (bare punctuation) are dropped rather than
  reported as permanently missing — `Gaps.report/1` does the same with a target.
  """
  def sentence_check(%{voice_report: nil}, _text), do: []

  def sentence_check(%{voice_report: report}, text) do
    counts = Map.new(report.by_take_count)

    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(fn token -> {token, normalize(token)} end)
    |> Enum.reject(fn {_token, word} -> word == "" end)
    |> Enum.map(fn {token, word} ->
      takes = Map.get(counts, word, 0)
      %{text: token, word: word, takes: takes, verdict: verdict(takes)}
    end)
  end

  @doc "Counts for the sentence check's summary line."
  def sentence_summary(rows) do
    Enum.reduce(rows, %{cuttable: 0, quotable: 0, missing: 0}, fn row, acc ->
      Map.update!(acc, row.verdict, &(&1 + 1))
    end)
  end

  defp verdict(0), do: :missing
  defp verdict(1), do: :quotable
  defp verdict(_n), do: :cuttable

  defp normalize(term) when is_binary(term), do: Index.normalize_word(term)
  defp normalize(_term), do: ""
end
