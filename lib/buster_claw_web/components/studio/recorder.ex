defmodule BusterClawWeb.Studio.Recorder do
  @moduledoc """
  The Studio's **Contribute** sub-tab: record a word into a voice bank
  (`STUDIO_ROADMAP` V.6–V.8).

  Presentation only. Every assign belongs to `StatusLive` and is prepared by
  `BusterClawWeb.Status.Contribute`, for the reason the whole home tab works that
  way: this renders behind `:if`, so a half-set-up recording session would empty
  the moment the operator glanced at Chat.

  ## The layout follows V.7's sketch, and its ordering is the feature

  Input, then level, then the word, then the button — in that order, because
  **the meter runs before you arm**. V.6 calls this the single behaviour that
  prevents most bad recordings: an operator who can watch the needle move sets
  their level without committing to a take, and digital clipping is
  unrecoverable rather than merely ugly.

  So the meter is not a decoration next to the record button. It is the control
  that comes first.

  ## What is deliberately not here

  **A level slider that only applies after capture.** V.7 is explicit: the web
  layer cannot set OS input gain, and a `GainNode` after the fact cannot undo
  clipping that already happened at the converter. A slider the operator
  believes is setting the microphone, which silently is not, is worse than no
  slider — so this links to System Settings and shows `sound_input_level`'s
  reading instead of faking the control.

  **A review-and-trim state.** V.7 wants waveform review with `wave_trim.js`
  after each take. That is real work and it is not here yet; a take currently
  saves or is refused. The gap is stated on the surface rather than implied by a
  button that does half of it.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Status.Recorder, as: State

  attr :recorder, :map, required: true

  def recorder(assigns) do
    ~H"""
    <div id="studio-record" class="flex min-h-0 flex-1 flex-col gap-2">
      <div class="flex shrink-0 items-baseline justify-between gap-2">
        <h3 class="font-display text-sm font-black uppercase tracking-tight">Record</h3>

        <button
          type="button"
          phx-click="contribute"
          phx-value-do="refresh"
          class="rounded border-2 border-base-content/30 px-2 py-1 text-xs font-semibold transition hover:bg-base-200"
        >
          Re-read devices
        </button>
      </div>

      <.notice notice={@recorder.notice} />

      <div class="grid min-h-0 flex-1 gap-3 lg:grid-cols-2">
        <.record_pane recorder={@recorder} />
        <.bank_pane recorder={@recorder} />
      </div>

      <p class="shrink-0 border-t border-base-content/15 pt-2 font-mono text-[0.65rem] text-base-content/45">
        Takes are saved to sounds/studio/ on this machine. Nothing is uploaded.
      </p>
    </div>
    """
  end

  attr :notice, :any, required: true

  defp notice(assigns) do
    ~H"""
    <p
      :if={@notice}
      class={[
        "shrink-0 rounded border-2 px-3 py-2 text-sm",
        case @notice do
          {:ok, _message} -> "border-success/40 bg-success/10 text-success"
          {:error, _message} -> "border-error/40 bg-error/10 text-error"
        end
      ]}
    >
      {elem(@notice, 1)}
    </p>
    """
  end

  attr :recorder, :map, required: true

  defp bank_pane(assigns) do
    ~H"""
    <section class="flex shrink-0 flex-col gap-2 rounded border-2 border-base-content/15 p-2">
      <h3 class="font-display text-sm font-black uppercase tracking-tight">New voice</h3>

      <%!-- Only CREATION lives here. Choosing the active bank is in the Library
            sidebar, because every pane reads it — browsing one voice while
            recording into another is the confusion that would cause. --%>
      <form phx-submit="contribute" class="flex shrink-0 gap-2">
        <input type="hidden" name="do" value="bank_create" />
        <input
          type="text"
          name="name"
          placeholder="aunt-mary"
          autocomplete="off"
          class="min-w-0 flex-1 rounded border-2 border-base-content/20 bg-base-100 px-2 py-1.5 text-sm"
        />
        <button
          type="submit"
          class="shrink-0 rounded border-2 border-base-content/30 px-3 py-1.5 text-xs font-semibold transition hover:bg-base-200"
        >
          Add
        </button>
      </form>

      <p class="font-mono text-[0.65rem] leading-relaxed text-base-content/50">
        A bank is one person through one microphone. Recording into the wrong one
        cannot be heard until a sentence is assembled from it.
      </p>
    </section>
    """
  end

  attr :recorder, :map, required: true

  defp record_pane(assigns) do
    assigns = assign(assigns, :recordable?, State.recordable?(assigns.recorder))

    ~H"""
    <section class="flex min-h-0 flex-col gap-2 rounded border-2 border-base-content/15 p-2">
      <h3 class="shrink-0 font-display text-sm font-black uppercase tracking-tight">
        Record
      </h3>

      <%!-- ONLY the hook's own DOM is inside phx-update="ignore", and the
            boundary is exact for a reason found by test: anything server-rendered
            INSIDE an ignored subtree can never be updated again — not in a test,
            and not in the browser either. The capability sentence and the word
            prompt below live OUTSIDE, because the server is what changes them.

            What is inside is what the hook paints from audio frames sixty times a
            second: the format readout, the meter, the peak hold, the clip latch,
            and the button whose label flips to Stop. `data-armed` is on the
            container rather than inside it — a container's ATTRIBUTES still patch
            when its children are ignored, which is the seam that lets the server
            arm a control the hook owns. --%>
      <div
        id="studio-recorder"
        phx-hook="VoiceRecorder"
        phx-update="ignore"
        data-device={@recorder.device}
        data-armed={to_string(@recordable?)}
        class="shrink-0 space-y-1"
      >
        <div data-role="format" class="font-mono text-[0.65rem] text-base-content/60">
          No input opened yet.
        </div>

        <div class="h-3 w-full overflow-hidden rounded-sm border border-base-content/20 bg-base-300">
          <div data-role="meter" class="h-full w-0 bg-success transition-[width] duration-75"></div>
        </div>

        <div class="flex justify-between font-mono text-[0.55rem] text-base-content/40">
          <span>-60</span><span>-24</span><span>-12</span><span>-6</span><span>0</span>
        </div>

        <div class="flex items-center gap-2 font-mono text-[0.65rem]">
          <span data-role="peak" class="text-base-content/60">peak —</span>
          <span
            data-role="clip"
            class="hidden rounded bg-error/25 px-1.5 py-0.5 font-bold uppercase tracking-wide text-error"
          >
            clip
          </span>
        </div>

        <button
          type="button"
          data-role="record"
          disabled
          class="mt-1 w-full rounded border-2 border-base-content/20 px-3 py-2 font-display text-sm font-black uppercase tracking-wide text-base-content/35 transition disabled:cursor-not-allowed"
        >
          ● Record
        </button>
      </div>

      <%!-- `phx-submit` is load-bearing, not decoration: without it the browser
            submits this single-input form NATIVELY on Enter, which navigates the
            page and remounts the LiveView — losing the word, the level and the
            armed state mid-session. Found in the packaged app 08-15 and pinned
            by `form_submit_test.exs`, which failed on this exact form. --%>
      <form phx-change="contribute" phx-submit="contribute" class="shrink-0">
        <input type="hidden" name="do" value="word" />
        <input
          type="text"
          name="word"
          value={@recorder.word}
          placeholder="The word or sentence you are about to say…"
          autocomplete="off"
          phx-debounce="200"
          class="w-full rounded border-2 border-base-content/20 bg-base-100 px-2 py-1.5 text-sm"
        />
      </form>

      <div
        id="studio-recorder-status"
        data-armed={to_string(@recordable?)}
        class="min-h-0 flex-1 overflow-y-auto px-1 py-1 text-sm text-base-content/60"
      >
        {capability_line(@recorder)}
      </div>
    </section>
    """
  end

  # The one sentence the operator reads when they cannot record. It names what
  # actually stopped them rather than "unavailable", because the three causes
  # need three different actions and two of them are not the operator's fault.
  defp capability_line(%{capture: :ready, word: word}) do
    case String.split(String.trim(word), ~r/\s+/u, trim: true) do
      [] ->
        "Type a word — or a whole sentence — then record yourself saying it."

      [one] ->
        "Ready. Press record, say “#{one}”, press stop. One word recorded on its " <>
          "own is the only kind of take nothing has to guess about."

      many ->
        "Ready. Press record and read the whole line. #{length(many)} words will be " <>
          "found inside it by alignment, which estimates where each one starts — " <>
          "faster than saying them one at a time, and less exact."
    end
  end

  defp capability_line(%{capture: :unproven}),
    do: "Checking whether this app can open a microphone…"

  defp capability_line(%{capture: :unsupported}),
    do:
      "This host exposes no microphone API at all, so recording cannot start here. " <>
        "Nothing is wrong with the app — try it in the desktop window."

  defp capability_line(%{capture: :denied, capture_detail: detail}) do
    "The microphone was refused" <>
      if(detail, do: " (#{detail})", else: "") <>
      ". A packaged build has not been granted microphone access yet " <>
      "(STUDIO_ROADMAP V.4a and V.5), so this is expected there. In System Settings → " <>
      "Privacy & Security → Microphone, check whether Buster Claw is listed."
  end
end
