defmodule BusterClawWeb.Studio.VoiceLibrary do
  @moduledoc """
  The **Voice Library** — the Studio's second tab, and the whole loop of working
  on a voice (`STUDIO_ROADMAP` Parts V and VI).

  ## Why one tab with a sidebar, and not three tabs

  These four activities are steps of one loop, not four features:

      browse the words ──▶ hear a take ──▶ build a sentence ──▶ hear it
              ▲                                                   │
              └──────────── record what was missing ◀─────────────┘

  Splitting them across rail buttons (which is what shipped for a few hours on
  08-16) described the *implementation* — a dictionary module and a recorder
  module — rather than the activity. The tell is the arrow back: you find a gap
  by building a sentence, and you close it by recording, and a rail that makes
  you leave the surface to do that is a rail in the way.

  So the sidebar navigates **inside** the tab, and it carries the two things that
  are true across every section: which voice you are working on, and how big it
  is.

  ## The sidebar holds the bank, and that is the important part

  A bank is one person through one microphone, and **banks never merge** (V.0).
  Every pane below reads the active bank: the word list, the sentence grade, the
  takes offered for audition, and the bank a new recording joins. Putting the
  selector anywhere else would let an operator browse one voice and record into
  another without the surface ever saying so.

  ## Presentation only

  Every assign belongs to `StatusLive`, prepared by `Studio.VoiceState` (corpus,
  phrase, selection, preview) and `Studio.RecorderState` (microphone, devices, banks).
  The panel renders behind `:if`, so state held here would not survive a glance
  at Chat.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Studio.Recorder
  alias BusterClawWeb.Studio.Sentence
  alias BusterClawWeb.Studio.Words

  attr :report, :any, required: true
  attr :error, :any, required: true
  attr :query, :string, required: true
  attr :sentence, :string, required: true
  attr :rows, :list, required: true
  attr :check, :list, required: true
  attr :section, :string, required: true
  attr :selected, :any, required: true
  attr :takes, :list, required: true
  attr :preview, :any, required: true
  attr :preview_error, :any, required: true
  attr :notice, :any, required: true
  attr :recorder, :map, required: true

  def library(assigns) do
    ~H"""
    <div id="studio-voice" class="ic-panel flex min-h-0 flex-1 gap-3 p-3">
      <.sidebar section={@section} report={@report} recorder={@recorder} />

      <div class="flex min-h-0 min-w-0 flex-1 flex-col gap-2">
        <p :if={@error} class="shrink-0 text-sm text-error">
          The corpus could not be read: {inspect(@error)}
        </p>

        <p
          :if={@report && @report.indexed_sources == 0}
          class="shrink-0 text-sm text-base-content/60"
        >
          This voice has nothing in it yet. Record a word or a sentence and it
          will appear here.
        </p>

        <p
          :if={@notice}
          class={[
            "shrink-0 rounded border-2 px-3 py-1.5 text-sm",
            case @notice do
              {:ok, _m} -> "border-success/40 bg-success/10 text-success"
              {:error, _m} -> "border-error/40 bg-error/10 text-error"
            end
          ]}
        >
          {elem(@notice, 1)}
        </p>

        <Words.words
          :if={@section == "words"}
          report={@report}
          query={@query}
          rows={@rows}
          selected={@selected}
          takes={@takes}
        />

        <Sentence.sentence
          :if={@section == "sentence"}
          report={@report}
          sentence={@sentence}
          check={@check}
          preview={@preview}
          preview_error={@preview_error}
        />

        <Recorder.recorder :if={@section == "record"} recorder={@recorder} />
      </div>
    </div>
    """
  end

  attr :section, :string, required: true
  attr :report, :any, required: true
  attr :recorder, :map, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside class="flex w-48 shrink-0 flex-col gap-3 border-r-2 border-base-content/15 pr-3">
      <div>
        <p class="font-mono text-[0.65rem] uppercase tracking-[0.2em] text-base-content/50">
          Voice
        </p>

        <%!-- The bank selector lives in the sidebar because every pane reads it.
              A phrase spliced across two speakers sounds broken and nothing
              downstream repairs it (STUDIO_ROADMAP V.0), so which voice is
              active must be visible while you browse, build AND record. --%>
        <form phx-change="contribute" class="mt-1">
          <input type="hidden" name="do" value="bank_select" />
          <select
            name="name"
            class="w-full rounded border-2 border-base-content/20 bg-base-100 px-2 py-1.5 text-sm"
          >
            <option
              :for={bank <- @recorder.banks}
              value={bank.name}
              selected={bank.name == @recorder.bank}
            >
              {bank.label}
            </option>
          </select>
        </form>
      </div>

      <nav class="flex flex-col gap-1" aria-label="Voice Library">
        <button
          :for={{key, label} <- [{"words", "Words"}, {"sentence", "Sentence"}, {"record", "Record"}]}
          type="button"
          phx-click="voice_section"
          phx-value-section={key}
          aria-current={@section == key && "page"}
          class={[
            "rounded border-2 px-3 py-1.5 text-left font-display text-xs font-bold uppercase tracking-wide transition",
            if(@section == key,
              do: "border-primary text-primary",
              else: "border-transparent text-base-content/55 hover:bg-base-200"
            )
          ]}
        >
          {label}
        </button>
      </nav>

      <div :if={@report} class="mt-auto space-y-0.5 font-mono text-[0.65rem] text-base-content/50">
        <p>{@report.distinct_words} words</p>
        <p>{@report.total_takes} takes</p>
        <%!-- The number this surface exists to make unmissable: a word with one
              take is a quotation, not a cut-up. --%>
        <p class={length(@report.single_take) > 0 && "text-warning"}>
          {length(@report.single_take)} quote only
        </p>
        <button
          type="button"
          phx-click="voice_refresh"
          class="mt-2 w-full rounded border-2 border-base-content/25 px-2 py-1 font-semibold uppercase tracking-wide transition hover:bg-base-200"
        >
          Re-read
        </button>
      </div>
    </aside>
    """
  end
end
