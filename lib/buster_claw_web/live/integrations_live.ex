defmodule BusterClawWeb.IntegrationsLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Integrations
  alias BusterClaw.Integrations.Integration

  @service_options [
    {"Sentry", "sentry"},
    {"GitHub", "github"},
    {"Umami", "umami"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Integrations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Integrations")
     |> assign(:editing_integration, nil)
     |> assign(:result, nil)
     |> assign_form(Integrations.change_integration(%Integration{}, %{service_type: "github"}))
     |> load_integrations()}
  end

  @impl true
  def handle_info({:integration_changed, _event, _integration}, socket) do
    {:noreply, load_integrations(socket)}
  end

  def handle_info({:integration_run, _run}, socket) do
    {:noreply, load_integrations(socket)}
  end

  # Ignore any unexpected message shape on the subscribed topic rather than
  # crashing the LiveView with a FunctionClauseError.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"integration" => params}, socket) do
    integration = socket.assigns.editing_integration || %Integration{}

    changeset =
      integration
      |> Integrations.change_integration(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"integration" => params}, socket) do
    case save_integration(socket.assigns.editing_integration, params) do
      {:ok, _integration} ->
        {:noreply,
         socket
         |> assign(:editing_integration, nil)
         |> assign(:result, "Integration saved.")
         |> assign_form(
           Integrations.change_integration(%Integration{}, %{service_type: "github"})
         )
         |> load_integrations()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    integration = Integrations.get_integration!(id)

    {:noreply,
     socket
     |> assign(:editing_integration, integration)
     |> assign(:result, nil)
     |> assign_form(Integrations.change_integration(integration))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_integration, nil)
     |> assign_form(Integrations.change_integration(%Integration{}, %{service_type: "github"}))}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    integration = Integrations.get_integration!(id)

    {:ok, _integration} =
      Integrations.update_integration(integration, %{enabled: !integration.enabled})

    {:noreply, load_integrations(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Integrations.get_integration!() |> Integrations.delete_integration()

    {:noreply,
     socket
     |> assign(:editing_integration, nil)
     |> assign(:result, "Integration deleted.")
     |> load_integrations()}
  end

  def handle_event("poll", %{"id" => id}, socket) do
    result =
      case Integrations.poll_integration(id) do
        {:ok, run} -> "Poll completed: #{run.records_fetched} records."
        {:error, run} -> "Poll failed: #{run.error}"
      end

    {:noreply, socket |> assign(:result, result) |> load_integrations()}
  end

  def handle_event("poll_all", _params, socket) do
    results = Integrations.poll_all()
    {ok_count, error_count} = Enum.reduce(results, {0, 0}, &count_poll_result/2)

    {:noreply,
     socket
     |> assign(:result, "Poll all completed: #{ok_count} ok, #{error_count} failed.")
     |> load_integrations()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <div class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:integrations} />

        <section class="space-y-6">
          <div class="flex justify-end">
            <button
              id="integrations-poll-all"
              class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85 disabled:opacity-40"
              phx-click="poll_all"
              disabled={@integrations == []}
            >
              Poll All
            </button>
          </div>

          <p
            :if={@result}
            id="integrations-result"
            class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm"
          >
            {@result}
          </p>

          <div class="grid gap-6 lg:grid-cols-[420px_minmax(0,1fr)]">
            <.form
              for={@form}
              id="integration-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
            >
              <div class="flex items-start justify-between gap-3">
                <h2 class="text-lg font-semibold">
                  {if @editing_integration, do: "Edit Integration", else: "New Integration"}
                </h2>
                <button
                  :if={@editing_integration}
                  type="button"
                  class="rounded border border-base-300 px-3 py-1.5 text-sm"
                  phx-click="cancel"
                >
                  Cancel
                </button>
              </div>

              <.input field={@form[:name]} label="Name" />
              <.input
                field={@form[:service_type]}
                label="Service"
                type="select"
                options={@service_options}
              />
              <.input field={@form[:base_url]} label="Base URL" />
              <.input field={@form[:token]} label="Token" type="password" autocomplete="off" />
              <.input
                field={@form[:webhook_secret]}
                label="Webhook Secret"
                type="password"
                autocomplete="off"
              />
              <.input
                field={@form[:config_text]}
                label="Config JSON"
                type="textarea"
                rows="8"
                placeholder={config_placeholder(@form[:service_type].value)}
                class="w-full rounded border border-base-300 bg-base-100 px-3 py-2 font-mono text-sm"
              />
              <.input
                field={@form[:polling_interval_minutes]}
                label="Polling Interval Minutes"
                type="number"
                min="1"
              />
              <.input field={@form[:enabled]} label="Enabled" type="checkbox" />

              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85">
                Save Integration
              </button>
            </.form>

            <div class="space-y-6">
              <section class="rounded-lg border border-base-300 bg-base-100">
                <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
                  {@integrations_count} integrations
                </div>

                <div class="divide-y divide-base-300">
                  <div
                    :for={integration <- @integrations}
                    id={"integration-#{integration.id}"}
                    class="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div class="min-w-0">
                      <h2 class="truncate text-sm font-semibold">{integration.name}</h2>
                      <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                        {integration.base_url}
                      </p>
                      <div class="mt-2 flex flex-wrap gap-2 text-xs">
                        <span class="rounded border border-base-300 px-2 py-1">
                          {integration.service_type}
                        </span>
                        <span class="rounded border border-base-300 px-2 py-1">
                          {if integration.enabled, do: "enabled", else: "disabled"}
                        </span>
                        <span class={status_class(integration.last_status)}>
                          {integration.last_status}
                        </span>
                      </div>
                      <p :if={integration.last_error} class="mt-2 line-clamp-2 text-xs text-error">
                        {integration.last_error}
                      </p>
                    </div>

                    <div class="flex flex-wrap gap-2">
                      <button
                        class="rounded border border-base-300 px-3 py-2 text-sm"
                        phx-click="poll"
                        phx-value-id={integration.id}
                      >
                        Poll
                      </button>
                      <button
                        class="rounded border border-base-300 px-3 py-2 text-sm"
                        phx-click="edit"
                        phx-value-id={integration.id}
                      >
                        Edit
                      </button>
                      <button
                        class="rounded border border-base-300 px-3 py-2 text-sm"
                        phx-click="toggle"
                        phx-value-id={integration.id}
                      >
                        Toggle
                      </button>
                      <button
                        class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                        phx-click="delete"
                        phx-value-id={integration.id}
                      >
                        Delete
                      </button>
                    </div>
                  </div>

                  <div
                    :if={@integrations == []}
                    class="px-4 py-10 text-center text-sm text-base-content/60"
                  >
                    No integrations configured yet.
                  </div>
                </div>
              </section>

              <section class="rounded-lg border border-base-300 bg-base-100">
                <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
                  Recent runs
                </div>

                <div class="divide-y divide-base-300">
                  <div :for={run <- @runs} id={"integration-run-#{run.id}"} class="px-4 py-3">
                    <div class="flex flex-wrap items-center justify-between gap-2 text-sm">
                      <div class="font-semibold">
                        {(run.integration && run.integration.name) || "Deleted integration"}
                      </div>
                      <span class={run_status_class(run.status)}>{run.status}</span>
                    </div>
                    <p class="mt-1 text-xs text-base-content/60">
                      {run.trigger} · {run.records_fetched} records · {run.started_at}
                    </p>
                    <p :if={run.document} class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {run.document.artifact_path}
                    </p>
                    <p :if={run.error} class="mt-1 line-clamp-2 text-xs text-error">{run.error}</p>
                  </div>

                  <div :if={@runs == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                    No integration runs recorded yet.
                  </div>
                </div>
              </section>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp save_integration(nil, params), do: Integrations.create_integration(params)

  defp save_integration(%Integration{} = integration, params),
    do: Integrations.update_integration(integration, params)

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp load_integrations(socket) do
    integrations = Integrations.list_integrations()

    socket
    |> assign(:service_options, @service_options)
    |> assign(:integrations, integrations)
    |> assign(:integrations_count, length(integrations))
    |> assign(:runs, Integrations.list_runs())
  end

  defp count_poll_result({:ok, _run}, {ok_count, error_count}), do: {ok_count + 1, error_count}
  defp count_poll_result({:error, _run}, {ok_count, error_count}), do: {ok_count, error_count + 1}

  defp config_placeholder("sentry"),
    do:
      ~s({"org":"acme","project":"checkout","environment":"production","limit":10,"auto_analyze_webhooks":false,"webhook_payload_excerpt":true,"dedupe_poll_snapshots":false,"dedupe_window_days":30})

  defp config_placeholder("umami"),
    do:
      ~s({"website_id":"site-id","timezone":"America/Los_Angeles","period":"24h","dedupe_poll_snapshots":false,"dedupe_window_days":30})

  defp config_placeholder(_service),
    do:
      ~s({"owner":"hightowerbuilds","repo":"buster-claw","limit":10,"auto_analyze_webhooks":false,"webhook_payload_excerpt":true,"dedupe_poll_snapshots":false,"dedupe_window_days":30})

  defp status_class("ok"), do: "rounded bg-success/15 px-2 py-1 text-success"
  defp status_class("error"), do: "rounded bg-error/15 px-2 py-1 text-error"
  defp status_class("disabled"), do: "rounded bg-warning/15 px-2 py-1 text-warning"
  defp status_class(_status), do: "rounded border border-base-300 px-2 py-1"

  defp run_status_class("ok"), do: "rounded bg-success/15 px-2 py-1 text-xs text-success"
  defp run_status_class("error"), do: "rounded bg-error/15 px-2 py-1 text-xs text-error"
  defp run_status_class(_status), do: "rounded border border-base-300 px-2 py-1 text-xs"
end
