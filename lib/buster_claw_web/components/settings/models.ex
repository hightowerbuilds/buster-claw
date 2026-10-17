defmodule BusterClawWeb.Settings.Models do
  @moduledoc """
  The markup of Configuration → **Agent & models**: the harness picker with its
  "why is this grey" note, the global default and free-text model forms, and
  the per-surface "in force" table.

  Extracted from `Settings.ModelsComponent.render/1` on 10-16 (CODE_QUALITY_SWEEP
  Phase 7). The component keeps the state and the five `handle_event` clauses;
  these components take `target` (the component itself) so every form still
  posts to it. `surface_label/1` and `backend_display/1` are public because the
  component's notes read them too.
  """
  use BusterClawWeb, :html

  alias BusterClaw.ModelPolicy

  attr :target, :any, required: true, doc: "the live_component the forms post to"
  attr :model_default_backend, :any, required: true
  attr :backend_choices, :list, required: true
  attr :backend_installed, :list, required: true
  attr :backend_missing, :list, required: true

  def harness_picker(assigns) do
    ~H"""
    <form
      id="model-default-backend-form"
      phx-change="model_default_backend"
      phx-target={@target}
    >
      <label class="block max-w-sm">
        <span class="ic-eyebrow">Global harness</span>
        <select
          name="backend"
          aria-label="Global default harness"
          class="select select-bordered mt-1 w-full font-mono text-xs"
        >
          <option value="auto" selected={is_nil(@model_default_backend)}>
            — auto — whichever CLI is found
          </option>
          <option
            :for={backend <- @backend_choices}
            value={backend}
            selected={@model_default_backend == backend}
            disabled={backend not in @backend_installed}
          >
            {backend_label(backend, backend in @backend_installed)}
          </option>
        </select>
      </label>
    </form>

    <%!-- Why a row is grey. Owed even once detection is perfect: "disabled with
          no explanation" was the whole of the first-launch experience on the
          08-15 build. Rendered only when something IS missing. --%>
    <p
      :if={@backend_missing != []}
      id="model-not-installed-note"
      class="max-w-2xl border-l-2 border-primary/60 pl-3 text-xs leading-5 text-base-content/60"
    >
      <strong>Greyed out means not found, not unsupported.</strong>
      A harness is disabled when Buster Claw could not find its executable. It
      looks on the PATH the app itself was launched with, and an app opened
      from Finder or the Dock inherits the system PATH rather than your
      shell's — which is why a CLI installed under <code class="font-mono">~/.local/bin</code>,
      <code class="font-mono">~/.bun/bin</code>
      or <code class="font-mono">/usr/local/bin</code>
      can read as missing here while <code class="font-mono">which claude</code>
      answers in a terminal. If you have not installed {missing_list(@backend_missing)}, install it and reopen this page.
    </p>
    """
  end

  attr :target, :any, required: true
  attr :model_default_backend, :any, required: true
  attr :model_default, :any, required: true
  attr :model_choices, :list, required: true
  attr :model_rows, :list, required: true

  def default_model_forms(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <form id="model-default-form" phx-change="model_default" phx-target={@target}>
        <label class="block">
          <span class="ic-eyebrow">
            Global default model · {backend_display(@model_default_backend)}
          </span>
          <select
            name="model"
            aria-label="Global default model"
            class="select select-bordered mt-1 w-full font-mono text-xs"
          >
            <option value="" selected={is_nil(@model_default)}>
              Unset — your {backend_display(@model_default_backend)} CLI decides
            </option>
            <option
              :for={model <- @model_choices}
              value={model}
              selected={@model_default == model}
            >
              {model}
            </option>
            <option
              :if={@model_default && @model_default not in @model_choices}
              value={@model_default}
              selected
            >
              {@model_default}
            </option>
          </select>
        </label>
        <p :if={@model_choices == []} class="pt-1 text-xs leading-5 text-base-content/60">
          {backend_display(@model_default_backend)} cannot list its own models from here, so there is nothing to pick —
          type the model beside this instead. A name only means something to
          its own harness: OpenCode wants <code>provider/model</code>.
        </p>
      </form>

      <form
        id="model-custom-form"
        phx-submit="model_custom"
        phx-target={@target}
        class="space-y-2"
      >
        <label class="block">
          <span class="ic-eyebrow">Any other model</span>
          <input
            type="text"
            name="model"
            value=""
            autocomplete="off"
            placeholder="Model ID or alias"
            class="input mt-1 w-full font-mono text-xs"
          />
        </label>
        <div class="flex flex-wrap items-center gap-2">
          <select
            name="target"
            aria-label="Where the typed model applies"
            class="select select-bordered select-sm min-w-0 flex-1 text-xs"
          >
            <option value="default">Global default</option>
            <option :for={{surface, _entry} <- @model_rows} value={surface}>
              {surface_label(surface)}
            </option>
          </select>
          <button type="submit" class={button_outline()}>Set</button>
        </div>
        <p class="text-xs leading-5 text-base-content/60">
          The CLI accepts aliases and models newer than the list above, so
          anything non-blank is accepted here.
        </p>
      </form>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :model_rows, :list, required: true
  attr :backend_choices, :list, required: true
  attr :backend_installed, :list, required: true

  def in_force_table(assigns) do
    ~H"""
    <div class="border-t-2 border-base-content/20 pt-2">
      <p class="ic-eyebrow py-2">In force, per surface</p>
      <div class="divide-y divide-base-300">
        <div
          :for={{surface, entry} <- @model_rows}
          class="flex flex-wrap items-start justify-between gap-4 py-4"
        >
          <div class="max-w-md min-w-0 space-y-1">
            <p class="text-sm font-semibold">{entry.description}</p>
            <p class="font-mono text-xs text-base-content/70">
              {backend_display(entry.backend)} · {model_display(entry.model, entry.backend)} · {source_note(
                entry.source
              )}
            </p>
            <p
              :if={entry.floor && entry.floor_applies}
              class="border-l-2 border-primary/60 pl-3 text-xs leading-5 text-base-content/60"
            >
              Floor: {entry.floor}. A cheaper model on this surface was measured
              inventing an answer instead of reporting a problem, so the global
              default cannot lower it. Naming this surface here still can.
            </p>
            <p
              :if={ModelPolicy.claude_only?(surface)}
              class="border-l-2 border-base-content/30 pl-3 text-xs leading-5 text-base-content/60"
            >
              Claude only. This surface's confinement is written in Claude's
              own flags, which the other harnesses reject outright — so there
              is no harness to choose here rather than a choice that would
              fail.
            </p>
          </div>

          <form
            :if={!ModelPolicy.claude_only?(surface)}
            id={"model-backend-#{surface}"}
            phx-change="model_backend"
            phx-target={@target}
            class="shrink-0"
          >
            <input type="hidden" name="surface" value={surface} />
            <select
              name="backend"
              aria-label={"Harness for #{surface_label(surface)}"}
              class="select select-bordered select-sm min-w-40 font-mono text-xs"
            >
              <option value="auto" selected={entry.backend_source == :auto}>
                — auto —
              </option>
              <option
                :for={backend <- @backend_choices}
                value={backend}
                selected={entry.backend_source != :auto and entry.backend == backend}
                disabled={backend not in @backend_installed}
              >
                {backend_label(backend, backend in @backend_installed)}
              </option>
            </select>
          </form>

          <form
            id={"model-surface-#{surface}"}
            phx-change="model_surface"
            phx-target={@target}
            class="shrink-0"
          >
            <input type="hidden" name="surface" value={surface} />
            <select
              name="model"
              aria-label={"Model for #{surface_label(surface)}"}
              class="select select-bordered select-sm min-w-56 font-mono text-xs"
            >
              <option value="" selected={entry.source != :surface}>— inherit —</option>
              <option
                :for={model <- entry.choices}
                value={model}
                selected={entry.source == :surface and entry.model == model}
              >
                {model}
              </option>
              <option
                :if={entry.source == :surface and entry.model not in entry.choices}
                value={entry.model}
                selected
              >
                {entry.model}
              </option>
            </select>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # Total on purpose. The empty case is unreachable behind the `:if` above, and
  # a helper that crashes when its guard is removed is a trap for whoever
  # removes it — which is exactly what happened when this was tested by removing
  # the guard.
  defp missing_list(backends) do
    case Enum.map(backends, &Atom.to_string/1) do
      [] -> "a harness"
      [one] -> "the #{one} CLI"
      names -> "the #{names |> Enum.drop(-1) |> Enum.join(", ")} or #{List.last(names)} CLI"
    end
  end

  @doc "How a harness choice reads; `nil` is the real choice, auto."
  def backend_display(nil), do: "auto"
  def backend_display(backend), do: Atom.to_string(backend)

  defp backend_label(backend, true), do: Atom.to_string(backend)
  defp backend_label(backend, false), do: Atom.to_string(backend) <> " (not installed)"

  defp model_display(nil, backend), do: "Your #{backend || :claude} CLI decides"
  defp model_display(model, _backend), do: model

  # Why the row resolved the way it did. `:cli` has to read as an answer, not as
  # a blank — "nothing is set" is a real, and shipped, state.
  defp source_note(:cli), do: "CLI default"
  defp source_note(:default), do: "from the global default"
  defp source_note(:surface), do: "set for this surface"
  defp source_note(:floor), do: "held at the floor — the global default is lower"

  @doc "The short head of the surface description, for notes and labels."
  def surface_label(:default), do: "The global default"

  def surface_label(surface) do
    ModelPolicy.surfaces() |> Map.fetch!(surface) |> String.split(" — ") |> List.first()
  end

  # A second copy of `SettingsLive`'s, deliberately: a shared button helper
  # belongs in core_components rather than being imported across a live_view /
  # live_component boundary for one class string.
  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
