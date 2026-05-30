defmodule BusterClawWeb.WebhooksLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Automation.Webhook
  alias BusterClaw.Webhooks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Webhooks")
     |> assign(
       :form,
       to_form(Webhooks.change_webhook(%Webhook{}, %{action: "ingest", enabled: true}))
     )
     |> load_webhooks()}
  end

  @impl true
  def handle_event("validate", %{"webhook" => params}, socket) do
    changeset = %Webhook{} |> Webhooks.change_webhook(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"webhook" => params}, socket) do
    case Webhooks.create_webhook(params) do
      {:ok, _webhook} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Webhooks.change_webhook(%Webhook{}, %{action: "ingest"})))
         |> load_webhooks()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Webhooks.get_webhook!() |> Webhooks.delete_webhook()
    {:noreply, load_webhooks(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <BusterClawWeb.AdvancedTabs.tabs active={:webhooks} />

        <section class="space-y-6">
          <div>
            <p class="ic-eyebrow">
              Local Automation
            </p>
            <h1 class="font-display text-5xl font-black uppercase tracking-tight">Webhooks</h1>
            <p class="mt-2 text-base text-base-content/70">
              Local POST endpoints under <code>/hooks/:name</code>
              for ingest, analysis, full pipelines, and custom commands.
            </p>
          </div>

          <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
            <.form
              for={@form}
              id="webhook-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
            >
              <h2 class="text-lg font-semibold">New Webhook</h2>
              <.input field={@form[:name]} label="Name" />
              <.input field={@form[:secret]} label="Secret" />
              <.input
                field={@form[:action]}
                label="Action"
                type="select"
                options={[
                  {"Ingest", "ingest"},
                  {"Analyze", "analyze"},
                  {"Full", "full"},
                  {"Command", "command"}
                ]}
              />
              <.input field={@form[:custom_cmd]} label="Custom Command" />
              <.input field={@form[:deliver_to]} label="Deliver To" />
              <.input field={@form[:enabled]} label="Enabled" type="checkbox" />
              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
                Save Webhook
              </button>
            </.form>

            <section class="rounded-lg border border-base-300 bg-base-100">
              <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
                {@webhooks_count} webhooks
              </div>
              <div class="divide-y divide-base-300">
                <div :for={webhook <- @webhooks} class="p-4">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <h2 class="font-semibold">{webhook.name}</h2>
                      <p class="text-sm text-base-content/70">
                        /hooks/{webhook.name} · {webhook.action}
                      </p>
                    </div>
                    <button
                      phx-click="delete"
                      phx-value-id={webhook.id}
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                    >
                      Delete
                    </button>
                  </div>
                </div>
                <div :if={@webhooks == []} class="p-6 text-sm text-base-content/60">
                  No webhooks configured.
                </div>
              </div>
            </section>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_webhooks(socket) do
    webhooks = Webhooks.list_webhooks()

    socket
    |> assign(:webhooks, webhooks)
    |> assign(:webhooks_count, length(webhooks))
  end
end
