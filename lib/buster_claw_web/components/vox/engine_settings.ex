defmodule BusterClawWeb.Vox.EngineSettings do
  @moduledoc """
  Vox2B's **How it speaks** panel: the six knobs handed to VoxCPM on every render,
  and the one number that says what changing them costs.

  Extracted from `BusterClawWeb.VoxComponent` on 09-05, the third panel to leave
  it in a day and the third time the FROZEN cap has bought a decomposition rather
  than a raised number — this one funded the spoken-messages feature moving in
  from Settings → Notify.

  ## The count is the point

  "N of 16 chimes are made with these settings" is not decoration. The render
  cache is keyed on the argv, so a new device or a new reference clip turns every
  made chime into a miss — forty minutes of work on the operator's machine. The
  panel says so in numbers rather than letting them find out at the button.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Voice.Engine

  @doc "The engine-settings form. `made` is the `{made, total}` chime count."
  attr :config, :map, required: true
  attr :note, :string, default: nil
  attr :made, :any, required: true
  attr :target, :any, required: true

  # What the current step count costs, measured on this machine. The number box
  # said nothing about consequence, which is how it stayed at a setting that
  # made the feature unusable here.
  attr :steps_note, :string, default: nil

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>How it speaks</h3>
      <p class="ic-vox-hint">
        Blank means the engine's own default. The one that matters is the reference clip — point
        it at your voice and every line is spoken in it.
      </p>

      <form
        phx-submit="engine-config-save"
        phx-target={@target}
        class="flex flex-col gap-3 text-sm"
      >
        <label class="flex flex-col gap-1">
          <span class="ic-eyebrow">Reference clip</span>
          <input
            type="text"
            name="config[reference_audio]"
            value={@config.reference_audio}
            placeholder="~/Desktop/me-ten-seconds.wav"
            class="input input-bordered input-sm w-full font-mono text-xs"
          />
        </label>

        <label class="flex flex-col gap-1">
          <span class="ic-eyebrow">Voice description — when not cloning</span>
          <input
            type="text"
            name="config[control]"
            value={@config.control}
            placeholder="warm, low, unhurried"
            class="input input-bordered input-sm w-full text-sm"
          />
        </label>

        <div class="grid gap-3 sm:grid-cols-3">
          <label class="flex flex-col gap-1">
            <span class="ic-eyebrow">Device</span>
            <select
              name="config[device]"
              class="select select-bordered select-sm font-mono text-xs"
            >
              <option value="" selected={is_nil(@config.device)}>
                auto ({Engine.device()})
              </option>
              <option value="cpu" selected={@config.device == "cpu"}>cpu</option>
              <option value="mps" selected={@config.device == "mps"}>
                mps — Apple silicon
              </option>
              <option value="cuda" selected={@config.device == "cuda"}>cuda</option>
            </select>
          </label>

          <%!-- Steps was a bare number box with the placeholder "default", and
                that is why it sat at the engine's 10 while a five-word line took
                nine and a half minutes. It is the single biggest lever on render
                time: measured 09-06, going from 10 steps to 4 took generation
                from 24.5 s to 9.6 s per step, dead linear. It does NOT scale the
                warm-up, which runs its ten iterations either way — so the wait
                went 585 s -> 380 s, not to 40% of it. The named options are the engine's own
                recommended range (4-30); a value set outside them is kept and
                shown rather than silently snapped to one. --%>
          <label class="flex flex-col gap-1">
            <span class="ic-eyebrow">Steps — speed against polish</span>
            <select
              name="config[inference_timesteps]"
              class="select select-bordered select-sm font-mono text-xs"
            >
              <option value="" selected={is_nil(@config.inference_timesteps)}>
                engine default (10)
              </option>
              <option
                :for={{value, label} <- step_presets()}
                value={value}
                selected={@config.inference_timesteps == value}
              >
                {label}
              </option>
              <option
                :if={
                  @config.inference_timesteps && @config.inference_timesteps not in preset_values()
                }
                value={@config.inference_timesteps}
                selected
              >
                {@config.inference_timesteps} — custom
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1">
            <span class="ic-eyebrow">Guidance</span>
            <input
              type="number"
              name="config[cfg_value]"
              value={@config.cfg_value}
              min="0.1"
              step="0.1"
              placeholder="default"
              class="input input-bordered input-sm font-mono text-xs"
            />
          </label>
        </div>

        <p :if={@steps_note} class="ic-vox-note">
          {@steps_note}
        </p>

        <label class="flex flex-col gap-1">
          <span class="ic-eyebrow">Engine path — only if it is somewhere unusual</span>
          <input
            type="text"
            name="config[engine_path]"
            value={@config.engine_path}
            placeholder={Engine.resolve() || "~/.buster-claw/voxcpm/bin/voxcpm"}
            class="input input-bordered input-sm w-full font-mono text-xs"
          />
        </label>

        <div class="flex flex-wrap items-center gap-2">
          <button type="submit" class="btn btn-primary btn-xs">Save</button>
          <button
            type="button"
            phx-click="engine-config-reset"
            phx-target={@target}
            class="btn btn-ghost btn-xs"
          >
            Engine defaults
          </button>
          <span class="ic-vox-note">{@note}</span>
        </div>

        <p class="ic-vox-note">
          {elem(@made, 0)} of {elem(@made, 1)} chimes are made with these settings.<span :if={
            elem(@made, 0) < elem(@made, 1)
          }>
              Changing the voice remakes all of them.</span>
        </p>
      </form>
    </section>
    """
  end

  # 4 and 20 are the ends of the engine's own recommended range; 6 is the one
  # worth having between them, because the cost is linear in this number and 6
  # is where a short line stops being an errand you leave the room for.
  defp step_presets do
    [{4, "4 — fastest"}, {6, "6 — quick"}, {10, "10 — engine default"}, {20, "20 — most polish"}]
  end

  defp preset_values, do: Enum.map(step_presets(), &elem(&1, 0))
end
