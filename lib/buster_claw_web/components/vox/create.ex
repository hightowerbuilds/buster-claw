defmodule BusterClawWeb.Vox.Create do
  @moduledoc """
  Vox2B's **Create** tab: the two things that make audio — a recording of the
  operator's voice, and a typed line rendered in it.

  Only the making. What has *been* made lives in `BusterClawWeb.Vox.Files`,
  which is the split the operator asked for on 09-05: *"the audio creation, audio
  files, and the rest of what is there."*

  The one thing that stays here rather than moving with the files is the
  **in-flight row** — a line being rendered right now, with its clock. Feedback
  belongs next to the box you typed in; a clip that appears in another tab while
  you are still looking at this one is not feedback, it is a surprise.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Voice.Config
  alias BusterClawWeb.Vox.Progress

  attr :engine, :map, required: true
  attr :mic_state, :any, default: nil
  attr :ref_note, :string, default: nil
  attr :clip_text, :string, required: true
  attr :clip_jobs, :map, required: true
  attr :clip_note, :string, default: nil
  attr :id, :string, required: true
  attr :target, :any, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>Record it once</h3>
      <p class="ic-vox-hint">
        Ten seconds of you talking normally. There is no training step: the recording
        <strong>is</strong>
        the learning, and the moment it saves every chime, clip and greeting is spoken in your
        voice.
      </p>

      <div class="flex flex-col gap-3 text-sm">
        <p class="border-l-2 border-base-content/20 pl-3 text-sm italic text-base-content/70">
          “The quick way to check a microphone is to read a sentence you didn't write,
          at the speed you'd say it to a friend across a kitchen.”
        </p>

        <%!-- phx-update="ignore": the hook owns this subtree — the meter, the
                status line, the button label — and a LiveView re-render must not
                wipe them mid-take. Same discipline as the Studio's recorder.

                `phx-target` is what routes the hook's two pushes at this component
                rather than at the host LiveView. A container's ATTRIBUTES still
                patch when its children are ignored, so the two directives do not
                fight. See `voice_recorder.js`: it pushes with `pushEventTo(this.el,
                …)`, which resolves to the LiveView when no `phx-target` is present
                — which is how the Studio's recorder keeps working untouched. --%>
        <div
          id={"#{@id}-recorder"}
          phx-hook="VoiceRecorder"
          phx-update="ignore"
          phx-target={@target}
          data-event-take="reference_take"
          data-event-report="reference_report"
          class="flex flex-col gap-2"
        >
          <div data-role="format" class="font-mono text-[0.625rem] text-base-content/55">
            opening the microphone…
          </div>

          <div class="relative h-2 overflow-hidden rounded-sm bg-base-300">
            <div data-role="target-zone" class="absolute inset-y-0 bg-success/25"></div>
            <div
              data-role="meter"
              class="relative h-full w-0 bg-success transition-[width] duration-75"
            >
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2 font-mono text-[0.6875rem]">
            <button type="button" data-role="record" class="btn btn-primary btn-xs">
              ● Record
            </button>
            <span data-role="peak" class="text-base-content/55">peak —</span>
            <span data-role="clip" class="text-error" hidden>clipped</span>
            <span data-role="status" class="text-base-content/55"></span>
          </div>
        </div>

        <p :if={match?({"denied", _}, @mic_state)} class="ic-vox-note text-error">
          The microphone was refused. macOS asks once — System Settings → Privacy &amp;
          Security → Microphone, and allow Buster Claw.
        </p>
        <p :if={match?({"unsupported", _}, @mic_state)} class="ic-vox-note">
          No microphone here. Recording works in the desktop app, not in a browser tab.
        </p>

        <span class="ic-vox-note">{@ref_note}</span>
      </div>
    </section>

    <section class="ic-vox-section">
      <h3>Hear yourself</h3>
      <p class="ic-vox-hint">
        Type a line and it comes back in your voice — the fastest way to judge a recording.
      </p>

      <div class="flex flex-col gap-3 text-sm">
        <form phx-submit="clip_make" phx-target={@target} class="flex flex-col gap-2">
          <textarea
            name="clip[text]"
            rows="2"
            maxlength="400"
            placeholder="Something you'd actually say."
            class="textarea textarea-bordered w-full text-sm"
          ><%= @clip_text %></textarea>

          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" disabled={not @engine.available?} class="btn btn-primary btn-xs">
              Make it
            </button>
            <span :if={not Config.cloning?()} class="ic-vox-note">
              No recording yet — a designed voice, not yours.
            </span>
            <span class="ic-vox-note">{@clip_note}</span>
          </div>
        </form>

        <%!-- In flight. `@clip_jobs` has been tracked since this surface was
                written and rendered NOWHERE — a queued clip showed one sentence
                and an empty textarea, and the line you had just typed vanished
                for the several minutes it took to make. These rows are the
                answer to that: your text stays on screen with a clock beside it,
                and the row becomes the player when the render lands. --%>
        <ul :if={@clip_jobs != %{}} class="flex flex-col gap-1.5">
          <li
            :for={{key, job} <- @clip_jobs}
            class="flex flex-wrap items-center gap-2 text-base-content/60"
          >
            <Progress.chip id={"#{@id}-clip-#{key}"} since={job.since} />
            <span class="min-w-0 flex-1 truncate text-xs italic">{job.text}</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end
end
