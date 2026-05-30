defmodule BusterClawWeb.HooksLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Automation.Hook
  alias BusterClaw.Hooks

  @impl true
  def mount(_params, _session, socket) do
    changeset = Hooks.change_hook(%Hook{}, %{event: "post_ingest", type: "shell", enabled: true})

    {:ok,
     socket
     |> assign(:page_title, "Hooks")
     |> assign(:form, to_form(changeset))
     |> assign(:result, nil)
     |> load_hooks()}
  end

  @impl true
  def handle_event("validate", %{"hook" => params}, socket) do
    changeset = %Hook{} |> Hooks.change_hook(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"hook" => params}, socket) do
    case Hooks.create_hook(params) do
      {:ok, _hook} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(Hooks.change_hook(%Hook{}, %{event: "post_ingest", type: "shell"}))
         )
         |> assign(:result, "Hook saved.")
         |> load_hooks()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    result =
      id
      |> Hooks.get_hook!()
      |> Hooks.test_hook()
      |> format_run()

    {:noreply, assign(socket, :result, result)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    hook = Hooks.get_hook!(id)
    {:ok, _hook} = Hooks.update_hook(hook, %{enabled: !hook.enabled})
    {:noreply, load_hooks(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Hooks.get_hook!() |> Hooks.delete_hook()
    {:noreply, socket |> assign(:result, "Hook deleted.") |> load_hooks()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <BusterClawWeb.AdvancedTabs.tabs active={:hooks} />

        <section class="space-y-6">
          <div>
            <p class="ic-eyebrow">
              Automation
            </p>
            <h1 class="font-display text-5xl font-black uppercase tracking-tight">Hooks</h1>
            <p class="mt-2 max-w-3xl text-base text-base-content/70">
              Run shell or webhook hooks around ingestion, analysis, reports, and errors.
            </p>
          </div>

          <p :if={@result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
            {@result}
          </p>

          <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
            <.form
              for={@form}
              id="hook-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
            >
              <h2 class="text-lg font-semibold">New Hook</h2>
              <.input field={@form[:name]} label="Name" />
              <.input
                field={@form[:event]}
                label="Event"
                type="select"
                options={[
                  {"Pre ingest", "pre_ingest"},
                  {"Post ingest", "post_ingest"},
                  {"Pre analysis", "pre_analysis"},
                  {"Post analysis", "post_analysis"},
                  {"Pre report", "pre_report"},
                  {"Post report", "post_report"},
                  {"On error", "on_error"}
                ]}
              />
              <.input
                field={@form[:type]}
                label="Type"
                type="select"
                options={[{"Shell", "shell"}, {"Webhook", "webhook"}]}
              />
              <.input field={@form[:target]} label="Target" />
              <.input field={@form[:async]} label="Async" type="checkbox" />
              <.input field={@form[:enabled]} label="Enabled" type="checkbox" />
              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
                Save Hook
              </button>
            </.form>

            <section class="rounded-lg border border-base-300 bg-base-100">
              <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
                {@hooks_count} hooks
              </div>
              <div class="divide-y divide-base-300">
                <div
                  :for={hook <- @hooks}
                  class="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold">{hook.name}</h2>
                    <p class="mt-1 truncate font-mono text-xs text-base-content/60">{hook.target}</p>
                    <div class="mt-2 flex flex-wrap gap-2 text-xs">
                      <span class="rounded border border-base-300 px-2 py-1">{hook.event}</span>
                      <span class="rounded border border-base-300 px-2 py-1">{hook.type}</span>
                      <span class="rounded border border-base-300 px-2 py-1">
                        {if hook.enabled, do: "enabled", else: "disabled"}
                      </span>
                    </div>
                  </div>

                  <div class="flex flex-wrap gap-2">
                    <button
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                      phx-click="test"
                      phx-value-id={hook.id}
                    >
                      Test
                    </button>
                    <button
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                      phx-click="toggle"
                      phx-value-id={hook.id}
                    >
                      Toggle
                    </button>
                    <button
                      class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                      phx-click="delete"
                      phx-value-id={hook.id}
                    >
                      Delete
                    </button>
                  </div>
                </div>
                <div :if={@hooks == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                  No hooks configured yet.
                </div>
              </div>
            </section>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_hooks(socket) do
    hooks = Hooks.list_hooks()

    socket
    |> assign(:hooks, hooks)
    |> assign(:hooks_count, length(hooks))
  end

  defp format_run({:ok, run}) do
    if run.success,
      do: "Hook test succeeded.",
      else: "Hook test failed: #{run.error || run.stdout}"
  end
end
