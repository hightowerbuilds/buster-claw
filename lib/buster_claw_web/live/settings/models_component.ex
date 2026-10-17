defmodule BusterClawWeb.Settings.ModelsComponent do
  @moduledoc """
  Settings → **Agents & models**: the harness picker, the global default
  model, the free-text escape hatch, and the per-surface "in force" table.

  Extracted from `SettingsLive` on 08-15, whole — the markup below is the page's
  markup, moved rather than rewritten, with `phx-target={@myself}` added to the
  five forms and one paragraph of new copy (see "Why disabled" below). It maps
  1:1 onto `BusterClaw.ModelPolicy`: every assign here is derived from that
  module and nothing else on the Configuration page reads any of them.

  ## Why this is a live_component and the home panels are not

  Configuration is a **route** (`live "/settings"`), not an `:if`-gated home
  panel. Home panels are discarded on every tab switch, which is why their
  state lives in the LiveView rather than in a component. Nothing here needs to
  outlive a sub-tab switch:
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

  import BusterClawWeb.Settings.Models

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

      <.harness_picker
        target={@myself}
        model_default_backend={@model_default_backend}
        backend_choices={@backend_choices}
        backend_installed={@backend_installed}
        backend_missing={@backend_missing}
      />

      <.default_model_forms
        target={@myself}
        model_default_backend={@model_default_backend}
        model_default={@model_default}
        model_choices={@model_choices}
        model_rows={@model_rows}
      />

      <p
        :if={@model_note}
        id="model-note"
        class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
      >
        {@model_note}
      </p>

      <.in_force_table
        target={@myself}
        model_rows={@model_rows}
        backend_choices={@backend_choices}
        backend_installed={@backend_installed}
      />
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
    # Each surface may use a different harness from the global default.
    |> assign(:model_choices, ModelPolicy.known_models(default_backend))
    |> assign(:model_rows, model_rows(in_force))
    |> assign(:model_default, ModelPolicy.model_for(default_backend, :default))
    |> assign_backend_missing()
  end

  defp model_rows(in_force) do
    Enum.map(ModelPolicy.surface_keys(), fn surface ->
      entry = Map.fetch!(in_force, surface)
      {surface, Map.put(entry, :choices, ModelPolicy.known_models(entry.backend))}
    end)
  end

  # Derived rather than asserted: the note reads off the same two lists the
  # `disabled` attribute does, so it cannot claim something is missing that the
  # picker offers live, or stay silent while every row is grey.
  defp assign_backend_missing(socket) do
    %{backend_choices: choices, backend_installed: installed} = socket.assigns
    assign(socket, :backend_missing, Enum.reject(choices, &(&1 in installed)))
  end

  # "auto" is a real choice — it hands the harness back to PATH detection — so it
  # maps to nil rather than being treated as "nothing selected".
  defp parse_backend_choice("auto"), do: nil

  defp parse_backend_choice(given),
    do: Enum.find(ModelPolicy.backends(), &(Atom.to_string(&1) == given))

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
    do: "Cleared. Every surface without a model of its own lets its CLI decide again."

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
end
