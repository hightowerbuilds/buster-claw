defmodule BusterClawWeb.Settings.ModelsComponent do
  @moduledoc """
  Configuration → **Agent & models**: the harness picker, the global default
  model, the free-text escape hatch, and the per-surface "in force" table.

  Extracted from `SettingsLive` on 08-15, whole — the markup below is the page's
  markup, moved rather than rewritten, with `phx-target={@myself}` added to the
  five forms and one paragraph of new copy (see "Why disabled" below). It maps
  1:1 onto `BusterClaw.ModelPolicy`: every assign here is derived from that
  module and nothing else on the Configuration page reads any of them.

  ## Why this is a live_component and Studio's panels are not

  Configuration is a **route** (`live "/settings"`), not an `:if`-gated home
  panel. Home panels are discarded on every tab switch, which is why
  `BusterClawWeb.Studio.MixState` holds the arranger's undo stack in the LiveView
  instead of in the component. Nothing here needs to outlive a sub-tab switch:
  every value is re-read from `ModelPolicy` in `update/2`, and `:model_note` —
  the one piece of genuinely transient state — *should* clear when you leave.
  So the component owns all of it, and its six `handle_event` clauses and ten
  helpers left `settings_live.ex` with the markup.

  ## Why disabled rather than hidden — and why it now says so

  A harness that is not installed renders **disabled, not hidden**: hiding it
  makes the app look like it does not support codex at all, and offering it live
  would fail at the moment a run was expected. That choice was made long ago and
  written down; what was never written down was the reason a given row is grey.

  The 08-15 DMG review opened the first signed build to a model picker with
  every option disabled and no sentence anywhere explaining it — because a
  double-clicked `.app` inherits launchd's PATH, not the operator's. Detection
  itself was fixed in `BusterClaw.AgentBackend`; the explanation is here, and it
  is owed whether or not detection is perfect. It renders only when something is
  actually missing, so a machine where all three resolve says nothing.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.AgentBackend
  alias BusterClaw.ModelPolicy

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Loaded once. `update/2` runs again on every parent render pass, and
    # re-running this would wipe `:model_note` — the confirmation line an
    # operator is still reading — on the next unrelated re-render.
    if Map.has_key?(socket.assigns, :model_rows) do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(:backend_choices, ModelPolicy.backends())
       |> assign(:backend_installed, AgentBackend.installed())
       |> assign(:model_note, nil)
       |> assign_model_policy()}
    end
  end

  # The pickers: an empty selection clears back to unset/inherit, which is the
  # shipped state — no `--model` flag reaches the CLI at all.
  @impl true
  def handle_event("model_default", %{"model" => model}, socket) do
    {:noreply, put_model(socket, :default, blank_to_nil(model))}
  end

  def handle_event("model_default_backend", %{"backend" => backend}, socket) do
    ModelPolicy.put_backend(:default, parse_backend_choice(backend))
    {:noreply, assign_model_policy(socket)}
  end

  def handle_event("model_backend", %{"surface" => surface, "backend" => backend}, socket) do
    ModelPolicy.put_backend(model_target(surface), parse_backend_choice(backend))
    {:noreply, assign_model_policy(socket)}
  end

  def handle_event("model_surface", %{"surface" => surface, "model" => model}, socket) do
    {:noreply, put_model(socket, model_target(surface), blank_to_nil(model))}
  end

  # The escape hatch. The CLI takes aliases and models newer than our list, so a
  # typed string goes straight to `ModelPolicy.put/2` — which validates it, and
  # refuses blank rather than reading it as "clear" (clearing is the picker's
  # job, and a blank that silently unset the default would be a nasty surprise).
  def handle_event("model_custom", %{"target" => target, "model" => model}, socket) do
    {:noreply, put_model(socket, model_target(target), String.trim(model))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="ic-panel space-y-4 p-6">
      <h2 class="ic-eyebrow">Agent harness &amp; models</h2>
      <p class="max-w-2xl text-sm text-base-content/70">
        Buster Claw drives your own agent CLI. Pick the <strong>harness</strong>
        first — a model name only means something inside its own harness — then
        the model within it. Left unset it passes no <code class="font-mono">--model</code>
        flag and detects the CLI itself, exactly as it always has. Your models
        are remembered per harness, so switching and switching back loses
        nothing.
      </p>

      <form
        id="model-default-backend-form"
        phx-change="model_default_backend"
        phx-target={@myself}
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

      <div class="grid gap-4 sm:grid-cols-2">
        <form id="model-default-form" phx-change="model_default" phx-target={@myself}>
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
          phx-target={@myself}
          class="space-y-2"
        >
          <label class="block">
            <span class="ic-eyebrow">Any other model</span>
            <input
              type="text"
              name="model"
              value=""
              autocomplete="off"
              placeholder="claude-sonnet-4-6"
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

      <p
        :if={@model_note}
        id="model-note"
        class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
      >
        {@model_note}
      </p>

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
                {backend_display(entry.backend)} · {model_display(entry.model)} · {source_note(
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
              phx-target={@myself}
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
              phx-target={@myself}
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
                  :for={model <- @model_choices}
                  value={model}
                  selected={entry.source == :surface and entry.model == model}
                >
                  {model}
                </option>
                <option
                  :if={entry.source == :surface and entry.model not in @model_choices}
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
    </section>
    """
  end

  # `in_force/0` is a map; the rows are materialized in `surface_keys/0` order
  # so the list is stable between renders instead of following map term order.
  defp assign_model_policy(socket) do
    in_force = ModelPolicy.in_force()

    # Models are stored per `{backend, surface}` since 08-03, so the global
    # default shown here is the one for the harness the default surface resolves
    # to — showing claude's default while running codex would be a lie.
    default_backend = ModelPolicy.backend_for(:default)

    socket
    |> assign(:model_default_backend, default_backend)
    # The offered models follow the CHOSEN harness, not claude forever. Resolved
    # here rather than at mount for that reason: a list that never changes would
    # have offered claude model IDs to an operator running opencode, which is the
    # one mistake `plausible_model?/2` exists to catch.
    |> assign(:model_choices, ModelPolicy.known_models(default_backend))
    |> assign(:model_rows, Enum.map(ModelPolicy.surface_keys(), &{&1, Map.fetch!(in_force, &1)}))
    |> assign(:model_default, ModelPolicy.model_for(default_backend, :default))
    |> assign_backend_missing()
  end

  # Derived rather than asserted: the note reads off the same two lists the
  # `disabled` attribute does, so it cannot claim something is missing that the
  # picker offers live, or stay silent while every row is grey.
  defp assign_backend_missing(socket) do
    %{backend_choices: choices, backend_installed: installed} = socket.assigns
    assign(socket, :backend_missing, Enum.reject(choices, &(&1 in installed)))
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

  # "auto" is a real choice — it hands the harness back to PATH detection — so it
  # maps to nil rather than being treated as "nothing selected".
  defp parse_backend_choice("auto"), do: nil

  defp parse_backend_choice(given),
    do: Enum.find(ModelPolicy.backends(), &(Atom.to_string(&1) == given))

  defp backend_display(nil), do: "auto"
  defp backend_display(backend), do: Atom.to_string(backend)

  defp backend_label(backend, true), do: Atom.to_string(backend)
  defp backend_label(backend, false), do: Atom.to_string(backend) <> " (not installed)"

  defp put_model(socket, target, model) do
    case ModelPolicy.put(target, model) do
      {:ok, in_force} ->
        socket
        |> assign_model_policy()
        |> assign(:model_note, model_note(target, model, in_force))

      {:error, reason} ->
        assign(socket, :model_note, model_error(reason))
    end
  end

  defp model_note(:default, nil, _in_force),
    do: "Cleared. Every surface without a model of its own lets your claude CLI decide again."

  defp model_note(:default, model, in_force) do
    held = for {surface, entry} <- in_force, entry.source == :floor, do: surface_label(surface)

    case Enum.sort(held) do
      [] -> "Global default set to #{model}."
      names -> "Global default set to #{model}. Held at the floor: #{Enum.join(names, ", ")}."
    end
  end

  defp model_note(surface, nil, _in_force),
    do: "#{surface_label(surface)} inherits the global default again."

  defp model_note(surface, model, _in_force), do: "#{surface_label(surface)} set to #{model}."

  defp model_error(:blank_model),
    do: "Type a model name — the picker is how you clear one back to unset."

  defp model_error({:unknown_surface, _surface}), do: "That is not a surface Buster Claw runs."
  defp model_error(_reason), do: "Could not save that model."

  defp model_display(nil), do: "Your claude CLI decides"
  defp model_display(model), do: model

  # Why the row resolved the way it did. `:cli` has to read as an answer, not as
  # a blank — "nothing is set" is a real, and shipped, state.
  defp source_note(:cli), do: "your claude CLI decides"
  defp source_note(:default), do: "from the global default"
  defp source_note(:surface), do: "set for this surface"
  defp source_note(:floor), do: "held at the floor — the global default is lower"

  # The short head of the surface description, for notes and labels.
  defp surface_label(:default), do: "The global default"

  defp surface_label(surface) do
    ModelPolicy.surfaces() |> Map.fetch!(surface) |> String.split(" — ") |> List.first()
  end

  # Never `String.to_atom/1` a form value: resolve it against the known keys.
  # An unrecognised target stays a string, and `ModelPolicy.put/2` rejects it.
  defp model_target("default"), do: :default

  defp model_target(target) when is_binary(target) do
    Enum.find(ModelPolicy.surface_keys(), target, &(Atom.to_string(&1) == target))
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # A second copy of `SettingsLive`'s, deliberately: this component is meant to
  # be readable without the page it was cut out of, and a shared button helper
  # belongs in core_components rather than being imported across a live_view /
  # live_component boundary for one class string.
  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
