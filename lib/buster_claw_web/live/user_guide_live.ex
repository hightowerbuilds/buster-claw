defmodule BusterClawWeb.UserGuideLive do
  @moduledoc """
  The **User Guide** tab — renders the guide (sourced from
  `daily-growth/user-guide/`, via `BusterClaw.UserGuide`) with in-page sub-tabs
  (Introduction / Setup / Daily Loop). Opened from the button on Home.

  Sub-tabs switch via LiveView events (no URL change), so the whole guide stays
  one top-level browser tab.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.UserGuide

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "User Guide")
     |> assign(:sections, UserGuide.sections())
     |> assign(:active, UserGuide.default_section())}
  end

  @impl true
  def handle_event("select_section", %{"key" => key}, socket) do
    active =
      Enum.find_value(socket.assigns.sections, socket.assigns.active, fn s ->
        if Atom.to_string(s.key) == key, do: s.key
      end)

    {:noreply, assign(socket, :active, active)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="flex flex-1 flex-col space-y-6">
        <div class="space-y-3 border-b-2 border-base-content/20 pb-5">
          <p class="ic-eyebrow">Reference</p>
          <h1 class="font-display text-3xl font-black uppercase tracking-tight">User Guide</h1>

          <nav
            id="user-guide-tabs"
            aria-label="User Guide sections"
            class="flex gap-2 overflow-x-auto rounded-lg border border-base-300 bg-base-100 p-1"
          >
            <button
              :for={section <- @sections}
              id={"user-guide-tab-#{section.key}"}
              type="button"
              phx-click="select_section"
              phx-value-key={section.key}
              class={[
                "whitespace-nowrap rounded px-4 py-2 text-sm font-semibold transition",
                if(@active == section.key,
                  do: "bg-base-content text-base-100",
                  else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
                )
              ]}
            >
              {section.label}
            </button>
          </nav>
        </div>

        <article
          id="user-guide-content"
          class="md-prose max-w-3xl rounded-lg border border-base-300 bg-base-100 p-6 shadow-sm"
        >
          {Phoenix.HTML.raw(current_html(@sections, @active))}
        </article>
      </section>
    </Layouts.app>
    """
  end

  defp current_html(sections, active) do
    case Enum.find(sections, &(&1.key == active)) do
      %{html: html} -> html
      _ -> ""
    end
  end
end
