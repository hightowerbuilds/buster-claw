defmodule BusterClawWeb.Vox.Files do
  @moduledoc """
  Vox2B's **Files** tab: everything the operator has made — reference recordings
  and rendered clips — in one place, with what you can do to each.

  Split out of the Create panels on 09-05 at the operator's word. The lists used
  to sit under the controls that produced them, which reads fine with two clips
  and badly with twenty.

  ## `Use as a sound` is the whole bridge to Settings → Notify

  A clip lives in `sounds/voice/`, the render cache, which is a **subdirectory**
  — and Notify's routing menu is `Sound.list/0`, which reads `sounds/`. Copying
  one up is all that stands between "a line I made" and "a sound my timer can
  play", which is why **Notify needed no change at all** to start offering them.

  It does not route the clip anywhere: `Clips.install/1` deliberately skips
  `Sound.assign/2`, so choosing where a sound plays stays one decision made in
  one place. Be aware of the library's own fallback, though — an unassigned key
  resolves to the first file alphabetically, so adding files can change what an
  unrouted alert plays. That is `Sound.path/0`, not this button.
  """
  use BusterClawWeb, :html

  attr :references, :list, required: true
  attr :clips, :list, required: true
  attr :ref_note, :string, default: nil
  attr :clip_note, :string, default: nil
  attr :target, :any, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>Your voice</h3>
      <p class="ic-vox-hint">
        Takes you have recorded. The one in use is what every chime, clip and greeting is
        cloned from.
      </p>
      <span class="ic-vox-note">{@ref_note}</span>

      <p :if={@references == []} class="ic-vox-note">
        Nothing recorded yet — the Create tab opens the microphone.
      </p>

      <ul :if={@references != []} class="flex flex-col gap-1.5">
        <li :for={ref <- @references} class="flex flex-wrap items-center gap-2">
          <audio
            controls
            preload="none"
            src={~p"/voice-audio/#{ref.name}"}
            class="h-7 max-w-[15rem]"
          >
          </audio>
          <span class="font-mono text-[0.6875rem] text-base-content/55">{ref.name}</span>
          <span :if={ref.current?} class="text-[0.6875rem] text-primary">in use</span>
          <button
            :if={not ref.current?}
            type="button"
            phx-click="reference_use"
            phx-target={@target}
            phx-value-name={ref.name}
            class="btn btn-ghost btn-xs"
          >
            Use this one
          </button>
          <button
            type="button"
            phx-click="reference_delete"
            phx-target={@target}
            phx-value-name={ref.name}
            data-claw-confirm={"Delete #{ref.name}?" <> if(ref.current?, do: " It is the voice in use — renders go back to a designed voice.", else: "")}
            class="btn btn-ghost btn-xs text-error"
          >
            Delete
          </button>
        </li>
      </ul>
    </section>

    <section class="ic-vox-section">
      <h3>Lines you have made</h3>
      <p class="ic-vox-hint">
        Every phrase rendered in your voice. <strong>Use as a sound</strong>
        copies one into the sound library, where Settings → Notify can route it at any alert.
      </p>
      <span class="ic-vox-note">{@clip_note}</span>

      <p :if={@clips == []} class="ic-vox-note">
        Nothing made yet — type a line on the Create tab.
      </p>

      <ul :if={@clips != []} class="flex flex-col gap-1.5">
        <li :for={clip <- @clips} class="flex flex-wrap items-center gap-2">
          <audio
            controls
            preload="none"
            src={~p"/voice-audio/#{clip.name}"}
            class="h-7 max-w-[15rem]"
          >
          </audio>
          <span class="min-w-0 flex-1 truncate text-xs">{clip.text}</span>
          <button
            type="button"
            phx-click="clip_install"
            phx-target={@target}
            phx-value-path={clip.path}
            class="btn btn-ghost btn-xs"
          >
            Use as a sound
          </button>
          <button
            type="button"
            phx-click="clip_forget"
            phx-target={@target}
            phx-value-path={clip.path}
            class="btn btn-ghost btn-xs"
          >
            Forget
          </button>
        </li>
      </ul>
    </section>
    """
  end
end
