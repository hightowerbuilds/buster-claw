defmodule BusterClawWeb.HomeWidget do
  @moduledoc """
  Home header corner widget: the Get Started / Calendar / Contacts card that
  fills the header gap to the right of the banner.

  Presentation only — the `select_widget_tab`, `quick_chat`, `add_contact`, and
  `remove_contact` events are handled by the parent LiveView (`StatusLive`).
  """
  use BusterClawWeb, :html

  @quick_prompts [
    "Please read through the introduction and BusterClawWorkspace and give me an explanation.",
    "Explain Buster Claw's Sentinel security layer — what it audits, the safe vs restricted trust tiers, and the gate on irreversible actions. Then exemplify it: run one safe command and one restricted command through the ./buster-claw CLI, show how each is recorded on the audit feed, and point me to the Security tab to watch it live.",
    "Give me an overview of everything you can do across my Google Workspace. Run `./buster-claw commands` to read your full catalog, then summarize the Google capabilities grouped by service — Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, and Tasks — noting for each which actions are read-only (safe) versus those that change or delete data and need confirmation.",
    "Check my mail and tell me what needs a reply.",
    "What can you do? Show me a few things to try."
  ]

  attr :tab, :string, required: true
  attr :entries, :list, required: true
  attr :today, Date, required: true
  attr :events, :list, required: true

  # Calendar + Contacts as a rectangle filling the header gap to the right of the
  # banner. The card is absolutely positioned to fill the widget box, so its
  # content scrolls instead of growing the header. When the CornerWidget hook
  # finds the header too narrow to fit the widget beside the banner it collapses
  # the widget to a right-edge bumper that pops the card back out on click.
  def corner_widget(assigns) do
    ~H"""
    <div
      id="home-corner-widget"
      phx-hook="CornerWidget"
      data-banner="#bc-heading"
      class="ic-corner-widget relative min-w-0"
    >
      <button
        type="button"
        data-corner-bumper
        aria-label="Show Calendar and Contacts"
        class="ic-corner-bumper"
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </button>

      <div
        data-corner-card
        class="ic-corner-card ic-panel flex flex-col overflow-hidden"
      >
        <div
          role="tablist"
          aria-label="Widget"
          class="flex gap-1 border-b-2 border-base-content/20 px-2 pt-2"
        >
          <%= for {key, text} <- [
            {"get-started", "Get Started"},
            {"calendar", "Calendar"},
            {"contacts", "Contacts"}
          ] do %>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@tab == key)}
              phx-click="select_widget_tab"
              phx-value-tab={key}
              class={[
                "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
                if(@tab == key,
                  do: "border-primary text-primary",
                  else: "border-transparent text-base-content/55 hover:text-base-content"
                )
              ]}
            >
              {text}
            </button>
          <% end %>
        </div>

        <div class="min-h-0 flex-1 overflow-auto">
          <div class={@tab != "get-started" && "hidden"}>
            <.get_started_panel />
          </div>
          <div class={@tab != "calendar" && "hidden"}>
            <.daily_calendar_panel today={@today} events={@events} />
          </div>
          <div class={@tab != "contacts" && "hidden"}>
            <BusterClawWeb.TrustedContactsPanel.panel entries={@entries} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp get_started_panel(assigns) do
    assigns = assign(assigns, :quick_prompts, @quick_prompts)

    ~H"""
    <section
      id="home-get-started"
      class="ic-panel flex flex-col overflow-hidden max-h-full"
    >
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Get Started</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          Get Started
        </h2>
        <p class="mt-1 text-sm text-base-content/65">
          Three steps and you're talking to Buster Claw (Google Workspace already connected).
        </p>
      </header>

      <div class="flex min-h-0 flex-1 flex-col overflow-auto">
        <details
          id="get-started-steps"
          phx-update="ignore"
          open
          class="group/steps border-b-2 border-base-content/15"
        >
          <summary class="ic-collapse-summary">
            <span class="ic-eyebrow">Setup steps</span>
            <.icon
              name="hero-chevron-down"
              class="size-4 shrink-0 text-base-content/55 transition group-open/steps:rotate-180"
            />
          </summary>

          <ol class="flex flex-col gap-4 px-5 pb-5">
            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                1
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Add your trusted contacts</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  In the panel below, list the senders Buster Claw may read and reply to.
                  Mail from anyone else is ignored.
                </p>
              </div>
            </li>

            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                2
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Install Claude Code</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  Buster Claw has no built-in AI — it drives your own Claude Code CLI headlessly.
                  Install it once with
                  <.copy_command command="brew install --cask claude-code" />, then
                  sign in (<span class="font-mono">claude</span> in a terminal).
                </p>
              </div>
            </li>

            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                3
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Chat with Buster Claw</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  Use the chat on the right. Ask it to triage your inbox, draft a reply, or
                  look something up — it runs headless Claude for you, no terminal needed.
                </p>
              </div>
            </li>
          </ol>
        </details>

        <details id="get-started-quick-chat" phx-update="ignore" open class="group/quick">
          <summary class="ic-collapse-summary">
            <span class="ic-eyebrow">Quick chat</span>
            <.icon
              name="hero-chevron-down"
              class="size-4 shrink-0 text-base-content/55 transition group-open/quick:rotate-180"
            />
          </summary>

          <div class="flex flex-col gap-2 px-5 pb-5">
            <button
              :for={prompt <- @quick_prompts}
              type="button"
              phx-click="quick_chat"
              phx-value-prompt={prompt}
              class="group flex items-center gap-3 rounded-sm border-2 border-base-content/25 px-3 py-2.5 text-left text-sm transition hover:border-primary hover:text-primary"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-5 shrink-0 text-base-content/55" />
              <span class="min-w-0 flex-1">{prompt}</span>
              <.icon name="hero-arrow-right" class="size-4 shrink-0 text-base-content/40" />
            </button>
          </div>
        </details>
      </div>
    </section>
    """
  end

  attr :command, :string, required: true

  defp copy_command(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 align-middle">
      <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[0.8rem]">{@command}</code>
      <button
        type="button"
        data-terminal-command-copy={@command}
        aria-label={"Copy command: #{@command}"}
        title="Copy"
        class="inline-flex shrink-0 items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3" />
        <span data-terminal-command-copy-label>Copy</span>
      </button>
    </span>
    """
  end

  attr :today, Date, required: true
  attr :events, :list, required: true

  defp daily_calendar_panel(assigns) do
    ~H"""
    <section id="home-daily-calendar" class="ic-panel self-start">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Today's Calendar</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            {Elixir.Calendar.strftime(@today, "%A, %B %-d")}
          </h2>
        </div>

        <.link
          navigate={~p"/calendar"}
          class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
        >
          Open Calendar
        </.link>
      </header>

      <div class="p-5">
        <ol :if={@events != []} class="divide-y divide-base-300 rounded border border-base-300">
          <li
            :for={event <- @events}
            id={"home-event-#{event.id}-#{Date.to_iso8601(event.date)}"}
            class="grid gap-3 px-4 py-3 text-sm sm:grid-cols-[7rem_minmax(0,1fr)] sm:items-start"
          >
            <div class="font-mono text-xs font-semibold uppercase tracking-wide text-primary">
              {event_time_label(event)}
            </div>
            <div class="min-w-0">
              <div class="flex min-w-0 items-center gap-2">
                <span class={["size-2.5 shrink-0 rounded-full", event_dot_class(event.color)]} />
                <h3 class="truncate font-semibold">{event.title}</h3>
                <span
                  :if={event.frequency}
                  class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold text-base-content/60"
                >
                  {event.frequency}
                </span>
              </div>
              <p
                :if={event.notes not in [nil, ""]}
                class="mt-1 line-clamp-2 text-sm text-base-content/60"
              >
                {event.notes}
              </p>
            </div>
          </li>
        </ol>

        <div
          :if={@events == []}
          class="rounded border border-dashed border-base-300 px-4 py-10 text-center text-sm text-base-content/60"
        >
          Nothing scheduled today.
        </div>
      </div>
    </section>
    """
  end

  defp event_time_label(%{start_time: nil}), do: "All day"

  defp event_time_label(%{start_time: start_time, end_time: nil}),
    do: format_event_time(start_time)

  defp event_time_label(%{start_time: start_time, end_time: end_time}),
    do: "#{format_event_time(start_time)}-#{format_event_time(end_time)}"

  defp format_event_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")

  defp event_dot_class(color) do
    case color do
      "work" -> "bg-info"
      "personal" -> "bg-secondary"
      "social" -> "bg-accent"
      "travel" -> "bg-warning"
      "health" -> "bg-success"
      "holiday" -> "bg-error"
      _ -> "bg-base-content/40"
    end
  end
end
