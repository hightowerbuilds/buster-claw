defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider
  alias BusterClaw.Runtime.Status

  @type_options [
    {"Anthropic (Claude)", "anthropic"},
    {"Google Gemini", "gemini"},
    {"OpenAI Codex", "codex"},
    {"OpenAI (Chat Completions)", "openai"},
    {"OpenRouter", "openrouter"},
    {"Ollama (local)", "ollama"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(status: Status.snapshot())
     |> assign(:flash_note, nil)
     |> load_providers()
     |> assign_new_form("anthropic")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       current_view: socket.assigns.live_action,
       page_title: page_title(socket.assigns.live_action)
     )}
  end

  @impl true
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

      provider ->
        {:ok, _} =
          provider |> Provider.changeset(%{active: false}) |> BusterClaw.Repo.update()

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-8">
        <div class="space-y-2">
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            {@status.phase}
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Buster Claw</h1>
          <p class="max-w-3xl text-base leading-7 text-base-content/70">
            Local-first research and chat runtime.
          </p>
        </div>

        <.models_panel
          providers={@providers}
          active_id={@active_id}
          form={@form}
          type_options={@type_options}
          flash_note={@flash_note}
        />

        <div class="grid gap-4 md:grid-cols-2">
          <.status_card
            title="Library Root"
            value={@status.library_root}
            ok?={@status.library_exists?}
          />
          <.status_card
            title="SQLite Database"
            value={@status.database_path}
            ok?={@status.database_exists?}
          />
          <.status_card title="PubSub" value={@status.pubsub} ok?={true} />
          <.status_card title="Endpoint" value={@status.endpoint} ok?={true} />
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <section class="rounded-lg border border-base-300 bg-base-100 p-5">
            <h2 class="text-lg font-semibold">Parity Views</h2>
            <div class="mt-4 grid gap-2 sm:grid-cols-2">
              <div
                :for={view <- @status.views}
                class={[
                  "rounded border px-3 py-2 text-sm",
                  if(view.key == @current_view,
                    do: "border-base-content bg-base-content text-base-100",
                    else: "border-base-300"
                  )
                ]}
              >
                <a href={view.path}>{view.label}</a>
              </div>
            </div>
          </section>

          <section class="rounded-lg border border-base-300 bg-base-100 p-5">
            <h2 class="text-lg font-semibold">Supervised Services</h2>
            <div class="mt-4 grid gap-2 sm:grid-cols-2">
              <div
                :for={service <- @status.services}
                class="rounded border border-base-300 px-3 py-2 text-sm"
              >
                {service}
              </div>
            </div>
          </section>
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
    <section class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-semibold">Models</h2>
        <p class="text-sm text-base-content/60">
          Add an API key, pick which one to use.
        </p>
      </div>

      <p :if={@flash_note} class="rounded border border-base-300 bg-base-200/40 px-3 py-2 text-sm">
        {@flash_note}
      </p>

      <form phx-change="activate_provider" class="space-y-1">
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

      <.form
        for={@form}
        phx-change="validate"
        phx-submit="add_provider"
        class="grid gap-3 sm:grid-cols-[180px_minmax(0,1fr)_200px_auto] sm:items-end"
      >
        <.input
          field={@form[:type]}
          type="select"
          label="Provider"
          options={@type_options}
        />
        <.input
          field={@form[:api_key]}
          type="password"
          label="API key"
          placeholder={api_key_placeholder(@form[:type].value)}
          autocomplete="off"
        />
        <.input
          field={@form[:model]}
          type="text"
          label="Model"
          placeholder={default_model(@form[:type].value)}
        />

        <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
          Add key
        </button>
      </.form>
    </section>
    """
  end

  defp page_title(:home), do: "Home"

  defp page_title(action) do
    action
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :ok?, :boolean, required: true

  defp status_card(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-5">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-base-content/70">{@title}</h2>
          <p class="mt-2 break-words font-mono text-sm">{@value}</p>
        </div>
        <span class={[
          "rounded-full px-2 py-1 text-xs font-semibold",
          if(@ok?, do: "bg-success/15 text-success", else: "bg-warning/15 text-warning")
        ]}>
          {if @ok?, do: "ready", else: "pending"}
        </span>
      </div>
    </section>
    """
  end

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
    name = auto_name(type, providers)

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
  defp default_model(_), do: ""

  defp api_key_placeholder("anthropic"), do: "sk-ant-..."
  defp api_key_placeholder("gemini"), do: "AIza..."
  defp api_key_placeholder("codex"), do: "sk-..."
  defp api_key_placeholder("openai"), do: "sk-..."
  defp api_key_placeholder("openrouter"), do: "sk-or-..."
  defp api_key_placeholder("ollama"), do: "(leave blank for local Ollama)"
  defp api_key_placeholder(_), do: ""
end
