defmodule BusterClawWeb.HomeWidget do
  @moduledoc """
  Home header corner widget: the card that fills the header gap to the right of
  the banner, and the rail that picks which of its three tabs is showing.

  **A rail and a dispatch, and nothing else** — the shape `explained_panel.ex` is
  cited for. Each tab is its own module under `BusterClawWeb.Widget`:

    * `Widget.PlacePanel` — Time & Place (the clock over the daycycle shader)
    * `Widget.CommsPanel` — Contacts (people, phone activity, trusted senders)
    * `Widget.NotifyPanel` — Notify (timers, alarms, reminders) and the fired
      modal that `NotifyLive` also renders

  Presentation only — `select_widget_tab`, `add_contact`, `remove_contact`,
  `notify_create` and the rest are handled by the parent LiveView (`StatusLive`).

  ## Why it was split (`WIDGET_BACKGROUND_ROADMAP` Phase 0)

  This file was **699 lines and FROZEN** — the size gate's tier for "already too
  big, may shrink and may never grow." Three tabs shared it because they share a
  *card*, which is a fact about layout, not about what any of them does: the
  three panels touched none of each other's helpers, which is why the cut was
  clean rather than negotiated.

  It was split **on its own, with no feature attached**, deliberately. The
  roadmap that needed the room is about making the Time & Place shader
  selectable, and a decomposition landing in the same commit as a behaviour
  change is how you lose track of which one broke something.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Widget.CommsPanel
  alias BusterClawWeb.Widget.NotifyPanel
  alias BusterClawWeb.Widget.PlacePanel

  # The widget's sub-tabs, in display order — ONE list, feeding both the rail
  # below and `StatusLive`'s `select_widget_tab` guard. It was two literals in
  # two files (in different orders) until 08-08, which is the third instance of
  # the shape that shipped Phone as a home tab the guard had never heard of.
  @widget_tabs [
    {"place", "Time & Place"},
    {"contacts", "Contacts"},
    {"notify", "Notify"}
  ]

  @doc "The widget's sub-tab keys, in display order. The rail and the guard share this."
  def widget_tab_keys, do: Enum.map(@widget_tabs, &elem(&1, 0))

  attr :tab, :string, required: true
  attr :contacts, :list, required: true
  attr :activity, :list, required: true
  attr :show_add, :boolean, required: true
  attr :trusted, :list, required: true
  attr :entries, :list, required: true
  attr :weather, :any, required: true
  attr :weather_form, :boolean, required: true
  attr :notifications, :list, required: true
  attr :notify_form, :any, required: true
  attr :notify_kind, :string, required: true
  attr :widget_bg, :map, required: true

  # Calendar + Contacts as a rectangle filling the header gap to the right of the
  # banner. The card is absolutely positioned to fill the widget box, so its
  # content scrolls instead of growing the header. When the CornerWidget hook
  # finds the header too narrow to fit the widget beside the banner it collapses
  # the widget to a right-edge bumper that pops the card back out on click.
  def corner_widget(assigns) do
    assigns = assign(assigns, :widget_tabs, @widget_tabs)

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
        class="ic-corner-card ic-panel ic-scanlines flex flex-col overflow-hidden"
      >
        <div
          role="tablist"
          aria-label="Widget"
          class="flex gap-1 border-b-2 border-base-content/20 px-2 pt-2"
        >
          <%= for {key, text} <- @widget_tabs do %>
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
          <div class={["h-full", @tab != "contacts" && "hidden"]}>
            <CommsPanel.comms_panel
              contacts={@contacts}
              activity={@activity}
              show_add={@show_add}
              trusted={@trusted}
              entries={@entries}
            />
          </div>
          <div class={["h-full", @tab != "place" && "hidden"]}>
            <PlacePanel.place_panel weather={@weather} form={@weather_form} bg={@widget_bg} />
          </div>
          <div class={["h-full", @tab != "notify" && "hidden"]}>
            <NotifyPanel.notify_panel
              notifications={@notifications}
              form={@notify_form}
              kind={@notify_kind}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
