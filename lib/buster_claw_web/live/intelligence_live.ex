defmodule BusterClawWeb.IntelligenceLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider

  @impl true
  def mount(_params, _session, socket) do
    changeset = Provider.changeset(%Provider{}, %{type: "openrouter", priority: 100})

    {:ok,
     socket
     |> assign(:page_title, "Intelligence")
     |> assign(:form, to_form(changeset))
     |> assign(:test_result, nil)
     |> load_providers()}
  end

  @impl true
  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      %Provider{}
      |> Provider.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("add_provider", %{"provider" => params}, socket) do
    case Providers.create_provider(params) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(Provider.changeset(%Provider{}, %{type: "openrouter", priority: 100}))
         )
         |> assign(:test_result, "Provider added.")
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("activate_provider", %{"id" => id}, socket) do
    provider = Providers.get_provider!(id)
    {:ok, _provider} = Providers.set_active_provider(provider)

    {:noreply, load_providers(assign(socket, :test_result, "#{provider.name} is active."))}
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    provider = Providers.get_provider!(id)
    {:ok, _provider} = Providers.delete_provider(provider)

    {:noreply, load_providers(assign(socket, :test_result, "Provider deleted."))}
  end

  def handle_event("test_provider", %{"id" => id}, socket) do
    provider = Providers.get_provider!(id)

    result =
      case Providers.test_provider(provider) do
        {:ok, response} -> "Connected: #{response}"
        {:error, reason} -> "Connection failed: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :test_result, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Models
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Intelligence</h1>
          <p class="mt-2 text-base text-base-content/70">
            Configure local and remote model providers for chat and analysis.
          </p>
        </div>

        <p :if={@test_result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
          {@test_result}
        </p>

        <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
          <.form
            for={@form}
            phx-change="validate"
            phx-submit="add_provider"
            class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">Add Provider</h2>
            <.input field={@form[:name]} label="Name" />
            <.input
              field={@form[:type]}
              label="Type"
              type="select"
              options={[
                {"Ollama", "ollama"},
                {"OpenRouter", "openrouter"},
                {"OpenAI", "openai"},
                {"Anthropic", "anthropic"},
                {"Custom", "custom"}
              ]}
            />
            <.input field={@form[:base_url]} label="Base URL" />
            <.input field={@form[:api_key]} label="API Key" type="password" />
            <.input field={@form[:model]} label="Model" />
            <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
              Add Provider
            </button>
          </.form>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              {@providers_count} providers
            </div>
            <div class="divide-y divide-base-300">
              <div
                :for={provider <- @providers}
                class="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="min-w-0">
                  <h2 class="truncate text-sm font-semibold">
                    {provider.name}
                    <span
                      :if={provider.active}
                      class="ml-2 rounded bg-success/15 px-2 py-1 text-xs text-success"
                    >
                      active
                    </span>
                  </h2>
                  <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                    {provider.base_url}
                  </p>
                  <p class="mt-2 text-sm text-base-content/70">{provider.type} · {provider.model}</p>
                </div>
                <div class="flex flex-wrap gap-2">
                  <button
                    class="rounded border border-base-300 px-3 py-2 text-sm"
                    phx-click="activate_provider"
                    phx-value-id={provider.id}
                  >
                    Activate
                  </button>
                  <button
                    class="rounded border border-base-300 px-3 py-2 text-sm"
                    phx-click="test_provider"
                    phx-value-id={provider.id}
                  >
                    Test
                  </button>
                  <button
                    class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                    phx-click="delete_provider"
                    phx-value-id={provider.id}
                  >
                    Delete
                  </button>
                </div>
              </div>
              <div :if={@providers == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No providers configured yet.
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_providers(socket) do
    providers = Providers.list_providers()

    socket
    |> assign(:providers, providers)
    |> assign(:providers_count, length(providers))
  end
end
