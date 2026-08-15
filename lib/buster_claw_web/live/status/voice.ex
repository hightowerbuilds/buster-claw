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

  alias BusterClaw.Notifications.Cutup.Gaps
  alias BusterClaw.Notifications.Cutup.Index

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
  end

  @doc """
  Load the corpus report unless it is already in hand.

  Called when the Studio's sub-tab becomes `voice`. Idempotent, so switching
  away and back does not re-read ten files.
  """
  def ensure_report(%{assigns: %{voice_report: %{}}} = socket), do: socket
  def ensure_report(socket), do: load_report(socket)

  @doc "Re-read the corpus from disk, discarding what was cached."
  def load_report(socket) do
    case Gaps.report([]) do
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
