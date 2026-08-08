defmodule BusterClawWeb.ActivityComponent do
  @moduledoc """
  Read-only Buster Claw minutes for the homepage Activity tab.

  The durable data remains in `BusterClaw.Journal`, preserving existing files,
  commands, and PubSub events. This component gives that record its correct
  product boundary: Activity is what Buster Claw did; Notes is the operator's
  editable Markdown notebook.
  """

  use BusterClawWeb, :live_component

  alias BusterClaw.ActivityReport
  alias BusterClaw.Journal
  alias BusterClaw.Markdown

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected, nil)
     |> assign(:day, nil)
     |> assign(:summary, empty_summary())
     |> assign(:loaded, false)
     |> stream(:days, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns.loaded and not Map.has_key?(assigns, :refresh) do
        socket
      else
        socket
        |> assign(:loaded, true)
        |> reload()
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_activity_day", %{"name" => name}, socket) do
    {:noreply, socket |> assign(:selected, name) |> reload()}
  end

  defp reload(socket) do
    selected = socket.assigns.selected || Journal.today_name()
    days = Enum.map(Journal.list(), &Map.put(&1, :id, "activity-day-#{&1.name}"))

    socket
    |> assign(:selected, selected)
    |> assign(:day, Journal.get(selected))
    |> assign(:summary, ActivityReport.summary())
    |> stream(:days, days, reset: true)
  end

  defp empty_summary do
    %{days: 7, runs: 0, commands: 0, handled: 0, open: 0}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="home-activity" class="flex min-h-0 flex-1 gap-3 lg:gap-4">
      <aside class="ic-panel flex w-56 shrink-0 flex-col overflow-hidden sm:w-64">
        <header class="border-b-2 border-base-content/20 px-3 py-3">
          <p class="font-display text-base font-black uppercase tracking-tight">BC Minutes</p>
          <p class="mt-0.5 font-mono text-[10px] uppercase tracking-wide text-base-content/50">
            Buster Claw's activity record
          </p>
        </header>

        <ul id="activity-days" phx-update="stream" class="min-h-0 flex-1 overflow-y-auto p-1.5">
          <li id="activity-days-empty" class="hidden only:block px-3 py-8 text-center">
            <.icon name="hero-clock" class="mx-auto size-7 text-base-content/25" />
            <p class="mt-2 font-mono text-xs text-base-content/50">No activity recorded yet.</p>
          </li>
          <li :for={{id, day} <- @streams.days} id={id}>
            <button
              type="button"
              phx-click="select_activity_day"
              phx-value-name={day.name}
              phx-target={@myself}
              aria-current={@selected == day.name && "page"}
              class={[
                "flex w-full items-center justify-between rounded-xs px-2.5 py-2 text-left font-mono text-xs transition",
                if(@selected == day.name,
                  do: "bg-primary/12 font-bold text-primary",
                  else: "text-base-content/70 hover:bg-base-content/7 hover:text-base-content"
                )
              ]}
            >
              <span>{day.name}</span>
              <span
                :if={day.name == Journal.today_name()}
                class="text-[9px] font-bold uppercase tracking-wide text-base-content/40"
              >
                Today
              </span>
            </button>
          </li>
        </ul>
      </aside>

      <section class="flex min-h-0 min-w-0 flex-1 flex-col gap-3">
        <header class="flex flex-wrap items-end justify-between gap-2">
          <div>
            <p class="font-mono text-[10px] font-bold uppercase tracking-[0.18em] text-primary">
              Activity
            </p>
            <h2 class="font-display text-xl font-black uppercase tracking-tight">{@selected}</h2>
          </div>
          <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
            Read-only · agent entries arrive live
          </p>
        </header>

        <div id="activity-summary" class="grid grid-cols-2 gap-2 lg:grid-cols-4">
          <.metric label="Runs" value={@summary.runs} />
          <.metric label="Commands" value={@summary.commands} />
          <.metric label="Handled" value={@summary.handled} />
          <.metric label="Open" value={@summary.open} />
        </div>
        <p class="-mt-1 text-right font-mono text-[9px] uppercase tracking-wide text-base-content/40">
          Totals cover the last {@summary.days} days; Open is current
        </p>

        <article
          :if={@day}
          id="activity-reading"
          class="ic-panel prose prose-sm min-h-0 max-w-none flex-1 overflow-y-auto p-4 dark:prose-invert"
        >
          {raw(Markdown.to_html(@day.body))}
        </article>

        <div
          :if={is_nil(@day)}
          id="activity-empty-state"
          class="ic-panel ic-scanlines flex min-h-0 flex-1 items-center justify-center p-8 text-center"
        >
          <div class="max-w-sm">
            <div class="mx-auto flex size-12 items-center justify-center rounded-full border-2 border-base-content/15 bg-base-content/5">
              <.icon name="hero-clock" class="size-6 text-primary" />
            </div>
            <p class="mt-4 font-display text-lg font-black uppercase tracking-tight">
              Nothing recorded for this day
            </p>
            <p class="mt-2 font-mono text-xs leading-relaxed text-base-content/50">
              BC Minutes begins when Buster Claw records its first activity entry.
            </p>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp metric(assigns) do
    ~H"""
    <div class="ic-panel relative overflow-hidden px-3 py-2.5">
      <div class="absolute inset-y-0 left-0 w-1 bg-primary/70"></div>
      <p class="font-mono text-[9px] font-bold uppercase tracking-[0.16em] text-base-content/45">
        {@label}
      </p>
      <p class="mt-0.5 font-display text-2xl font-black leading-none text-base-content">{@value}</p>
    </div>
    """
  end
end
