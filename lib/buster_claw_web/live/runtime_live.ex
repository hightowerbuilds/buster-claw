defmodule BusterClawWeb.RuntimeLive do
  @moduledoc """
  Runtime Control (Advanced tab): pick the active model/API key or hand the app
  off to a terminal agent. Moved off the home page.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.AgentMode
  alias BusterClaw.Commands
  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider

  @type_options [
    {"Anthropic (Claude)", "anthropic"},
    {"Google Gemini", "gemini"},
    {"OpenAI Codex", "codex"},
    {"OpenAI (Chat Completions)", "openai"},
    {"OpenRouter", "openrouter"},
    {"Ollama (local)", "ollama"},
    {"Custom OpenAI-compatible", "custom"}
  ]

  @activity_keep 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      AgentMode.subscribe_mode()
      AgentMode.subscribe_activity()
    end

    {:ok,
     socket
     |> assign(:page_title, "Runtime")
     |> assign(:flash_note, nil)
     |> assign(:mode, :api_key)
     |> assign(:agent_mode_on?, AgentMode.on?())
     |> assign(:activity, [])
     |> load_providers()
     |> assign_new_form("anthropic")}
  end

  @impl true
  def handle_event("select_mode", %{"mode" => mode}, socket)
      when mode in ["api_key", "terminal_agent"] do
    {:noreply, assign(socket, :mode, String.to_atom(mode))}
  end

  def handle_event("toggle_agent_mode", _params, socket) do
    AgentMode.toggle()
    {:noreply, socket}
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    prev_type = socket.assigns.form[:type].value
    new_type = Map.get(params, "type")

    socket =
      if new_type != prev_type do
        assign_new_form(socket, new_type)
      else
        changeset =
          %Provider{}
          |> Provider.changeset(params)
          |> Map.put(:action, :validate)

        assign(socket, :form, to_form(changeset, as: :provider))
      end

    {:noreply, socket}
  end

  def handle_event("add_provider", %{"provider" => params}, socket) do
    params = fill_defaults(params, socket.assigns.providers)

    case Providers.create_provider(params) do
      {:ok, provider} ->
        maybe_set_active(provider, socket.assigns.providers)

        {:noreply,
         socket
         |> assign(:flash_note, "Saved #{provider.name}.")
         |> load_providers()
         |> assign_new_form(params["type"])}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :provider))}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    provider = Providers.get_provider!(id)
    {:ok, _} = Providers.delete_provider(provider)

    {:noreply,
     socket
     |> assign(:flash_note, "Deleted #{provider.name}.")
     |> load_providers()}
  end

  def handle_event("activate_provider", %{"provider" => %{"active_id" => ""}}, socket) do
    case Providers.active_provider() do
      nil ->
        {:noreply, socket}

      _provider ->
        :ok = Providers.clear_active()

        {:noreply,
         socket
         |> assign(:flash_note, "No active key.")
         |> load_providers()}
    end
  end

  def handle_event("activate_provider", %{"provider" => %{"active_id" => id}}, socket) do
    provider = Providers.get_provider!(id)
    {:ok, _} = Providers.set_active_provider(provider)

    {:noreply,
     socket
     |> assign(:flash_note, "Using #{provider.name}.")
     |> load_providers()}
  end

  def handle_event("test_provider", %{"id" => id}, socket) do
    provider = Providers.get_provider!(id)

    note =
      case Providers.test_provider(provider) do
        {:ok, response} -> "#{provider.name}: #{response}"
        {:error, reason} -> "#{provider.name}: #{BusterClawWeb.ErrorFormatter.format(reason)}"
      end

    {:noreply, assign(socket, :flash_note, note)}
  end

  @impl true
  def handle_info({:agent_mode, value}, socket) do
    {:noreply, assign(socket, :agent_mode_on?, value)}
  end

  def handle_info({:activity, payload}, socket) do
    activity = [payload | socket.assigns.activity] |> Enum.take(@activity_keep)
    {:noreply, assign(socket, :activity, activity)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-4">
        <div>
          <p class="ic-eyebrow">
            Runtime Control
          </p>
          <h1 class="font-display text-4xl font-black uppercase tracking-tight">
            Agent Handoff & API Keys
          </h1>
          <p class="mt-1 text-sm text-base-content/60">
            Choose the active model path when you need to change who drives the app.
          </p>
        </div>

        <BusterClawWeb.AdvancedTabs.tabs active={:runtime} />

        <div class="space-y-5">
          <div class="flex gap-2 rounded-lg border border-base-300 bg-base-100 p-1">
            <button
              type="button"
              phx-click="select_mode"
              phx-value-mode="api_key"
              class={[
                "flex-1 rounded px-4 py-2 text-sm font-semibold transition-colors",
                if(@mode == :api_key,
                  do: "bg-base-content text-base-100",
                  else: "text-base-content/70 hover:bg-base-200"
                )
              ]}
            >
              Use an API key
            </button>
            <button
              type="button"
              phx-click="select_mode"
              phx-value-mode="terminal_agent"
              class={[
                "flex-1 rounded px-4 py-2 text-sm font-semibold transition-colors",
                if(@mode == :terminal_agent,
                  do: "bg-base-content text-base-100",
                  else: "text-base-content/70 hover:bg-base-200"
                )
              ]}
            >
              Hand off to a terminal agent
            </button>
          </div>

          <.models_panel
            :if={@mode == :api_key}
            providers={@providers}
            active_id={@active_id}
            form={@form}
            type_options={@type_options}
            flash_note={@flash_note}
          />

          <.agent_panel
            :if={@mode == :terminal_agent}
            agent_mode_on?={@agent_mode_on?}
            activity={@activity}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :providers, :list, required: true
  attr :active_id, :any, required: true
  attr :form, :any, required: true
  attr :type_options, :list, required: true
  attr :flash_note, :string, default: nil

  defp models_panel(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-semibold">Models</h2>
        <p class="text-sm text-base-content/60">
          Add an API key, pick which one to use.
        </p>
      </div>

      <p :if={@flash_note} class="rounded border border-base-300 bg-base-200/40 px-3 py-2 text-sm">
        {@flash_note}
      </p>

      <form id="active-provider-form" phx-change="activate_provider" class="space-y-1">
        <label class="block text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Active key
        </label>
        <select
          name="provider[active_id]"
          class="w-full rounded border border-base-300 bg-base-100 px-3 py-2 text-sm"
          disabled={@providers == []}
        >
          <option value="" selected={@active_id == nil}>
            {if @providers == [], do: "No keys saved yet", else: "— none —"}
          </option>
          <option
            :for={p <- @providers}
            value={p.id}
            selected={@active_id == p.id}
          >
            {provider_label(p)}
          </option>
        </select>
      </form>

      <div :if={@providers != []} class="divide-y divide-base-300 rounded border border-base-300">
        <div
          :for={p <- @providers}
          class="flex items-center justify-between gap-3 px-3 py-2 text-sm"
        >
          <div class="min-w-0">
            <p class="truncate font-medium">{provider_label(p)}</p>
            <p class="truncate text-xs text-base-content/60">
              key {mask_key(p.api_key)}
              <span :if={p.active} class="ml-2 rounded bg-success/15 px-2 py-0.5 text-success">
                active
              </span>
            </p>
          </div>
          <div class="flex flex-shrink-0 gap-2">
            <button
              class="rounded border border-base-300 px-2 py-1 text-xs"
              phx-click="test_provider"
              phx-value-id={p.id}
            >
              Test
            </button>
            <button
              class="rounded border border-error/40 px-2 py-1 text-xs text-error"
              phx-click="delete_provider"
              phx-value-id={p.id}
              data-confirm={"Delete #{p.name}?"}
            >
              Delete
            </button>
          </div>
        </div>
      </div>

      <.form
        for={@form}
        id="provider-form"
        phx-change="validate"
        phx-submit="add_provider"
        class="grid gap-3 sm:grid-cols-2"
      >
        <.input
          field={@form[:name]}
          type="text"
          label="Name (optional)"
          placeholder="Auto-named by provider type"
        />
        <.input
          field={@form[:type]}
          type="select"
          label="Provider"
          options={@type_options}
        />
        <.input
          field={@form[:base_url]}
          type="text"
          label="Base URL (optional)"
          placeholder={base_url_placeholder(@form[:type].value)}
        />
        <.input
          field={@form[:model]}
          type="text"
          label="Model"
          placeholder={default_model(@form[:type].value)}
        />
        <div class="sm:col-span-2">
          <.input
            field={@form[:api_key]}
            type="password"
            label="API key"
            placeholder={api_key_placeholder(@form[:type].value)}
            autocomplete="off"
          />
        </div>
        <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 sm:col-span-2">
          Add key
        </button>
      </.form>
    </section>
    """
  end

  attr :agent_mode_on?, :boolean, required: true
  attr :activity, :list, required: true

  defp agent_panel(assigns) do
    assigns = assign(assigns, :commands, Commands.list_commands())

    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold">Terminal Agent</h2>
          <p class="text-sm text-base-content/60">
            Hand control to an external agent (Claude Code, Codex) running in a terminal next
            to this window. The agent drives Buster Claw through the MCP server while you watch
            its activity here.
          </p>
        </div>
        <button
          type="button"
          phx-click="toggle_agent_mode"
          class={[
            "rounded px-4 py-2 text-sm font-semibold",
            if(@agent_mode_on?,
              do: "border border-error/40 text-error",
              else: "bg-base-content text-base-100"
            )
          ]}
        >
          {if @agent_mode_on?, do: "End agent mode", else: "Ready for agent"}
        </button>
      </div>

      <div
        :if={@agent_mode_on?}
        class="rounded border border-success/40 bg-success/10 px-3 py-2 text-sm font-semibold text-success"
      >
        Agent mode is on. Watch the activity feed below.
      </div>

      <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div class="rounded border border-base-300">
          <div class="border-b border-base-300 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Roster · {length(@commands)} commands
          </div>
          <ul class="max-h-96 divide-y divide-base-300 overflow-y-auto text-sm">
            <li :for={cmd <- @commands} class="flex items-baseline gap-2 px-3 py-2">
              <code class="font-mono text-xs">{cmd.name}</code>
              <span class="truncate text-xs text-base-content/60">{cmd.description}</span>
            </li>
          </ul>
        </div>

        <div class="rounded border border-base-300">
          <div class="border-b border-base-300 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Activity
          </div>
          <ul class="max-h-96 divide-y divide-base-300 overflow-y-auto text-sm">
            <li
              :for={event <- @activity}
              class="flex flex-col gap-1 px-3 py-2"
            >
              <div class="flex items-baseline gap-2">
                <code class="font-mono text-xs">{event.name}</code>
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs font-semibold",
                  case event.result do
                    :ok -> "bg-success/15 text-success"
                    :error -> "bg-error/15 text-error"
                    _ -> "bg-base-200 text-base-content/60"
                  end
                ]}>
                  {event.result}
                </span>
                <span class="ml-auto font-mono text-xs text-base-content/50">
                  {format_time(event.at)}
                </span>
              </div>
            </li>
            <li
              :if={@activity == []}
              class="px-3 py-8 text-center text-xs text-base-content/50"
            >
              No activity yet. The agent's command invocations will appear here.
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp format_time(%DateTime{} = dt), do: Elixir.Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp load_providers(socket) do
    providers = Providers.list_providers()
    active = Enum.find(providers, & &1.active)

    socket
    |> assign(:providers, providers)
    |> assign(:active_id, active && active.id)
    |> assign(:type_options, @type_options)
  end

  defp assign_new_form(socket, type) do
    type = if type in Enum.map(@type_options, &elem(&1, 1)), do: type, else: "anthropic"

    changeset =
      Provider.changeset(%Provider{}, %{
        type: type,
        model: default_model(type),
        priority: 100
      })

    assign(socket, :form, to_form(changeset, as: :provider))
  end

  defp fill_defaults(params, providers) do
    type = Map.get(params, "type", "anthropic")
    model = blank_to_default(Map.get(params, "model"), default_model(type))
    name = blank_to_default(Map.get(params, "name"), auto_name(type, providers))

    params
    |> Map.put("model", model)
    |> Map.put("name", name)
    |> Map.put("priority", "100")
  end

  defp maybe_set_active(provider, existing_providers) do
    if Enum.all?(existing_providers, &(!&1.active)) do
      {:ok, _} = Providers.set_active_provider(provider)
    end
  end

  defp auto_name(type, providers) do
    label = type_label(type)
    used = Enum.map(providers, & &1.name)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn n ->
      candidate = if n == 1, do: label, else: "#{label} #{n}"
      if candidate in used, do: nil, else: candidate
    end)
  end

  defp type_label(type) do
    Enum.find_value(@type_options, type, fn {label, value} ->
      if value == type, do: label
    end)
  end

  defp provider_label(provider),
    do: "#{type_label(provider.type)} · #{provider.model}"

  defp mask_key(nil), do: "(none)"
  defp mask_key(""), do: "(none)"

  defp mask_key(key) do
    tail = key |> String.slice(-4, 4)
    "••••" <> tail
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp default_model("anthropic"), do: "claude-sonnet-4-6"
  defp default_model("gemini"), do: "gemini-2.0-flash"
  defp default_model("codex"), do: "codex-mini-latest"
  defp default_model("openai"), do: "gpt-4o"
  defp default_model("openrouter"), do: "openai/gpt-4o"
  defp default_model("ollama"), do: "llama3"
  defp default_model("custom"), do: ""
  defp default_model(_), do: ""

  defp api_key_placeholder("anthropic"), do: "sk-ant-..."
  defp api_key_placeholder("gemini"), do: "AIza..."
  defp api_key_placeholder("codex"), do: "sk-..."
  defp api_key_placeholder("openai"), do: "sk-..."
  defp api_key_placeholder("openrouter"), do: "sk-or-..."
  defp api_key_placeholder("ollama"), do: "(leave blank for local Ollama)"
  defp api_key_placeholder("custom"), do: "(if your endpoint requires one)"
  defp api_key_placeholder(_), do: ""

  defp base_url_placeholder("anthropic"), do: "https://api.anthropic.com"
  defp base_url_placeholder("gemini"), do: "https://generativelanguage.googleapis.com"
  defp base_url_placeholder("codex"), do: "https://api.openai.com/v1"
  defp base_url_placeholder("openai"), do: "https://api.openai.com/v1"
  defp base_url_placeholder("openrouter"), do: "https://openrouter.ai/api/v1"
  defp base_url_placeholder("ollama"), do: "http://127.0.0.1:11434"
  defp base_url_placeholder("custom"), do: "https://your-endpoint/v1"
  defp base_url_placeholder(_), do: ""
end
