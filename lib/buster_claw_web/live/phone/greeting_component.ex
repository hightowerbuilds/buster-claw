defmodule BusterClawWeb.Phone.GreetingComponent do
  @moduledoc "Status and explicit reset of an existing phone greeting."
  use BusterClawWeb, :live_component

  alias BusterClaw.Telephony.Relay

  @impl true
  def mount(socket) do
    {:ok, assign(socket, status: :unchecked, busy: false, error: nil)}
  end

  @impl true
  def handle_event("check", _, %{assigns: %{busy: false}} = socket) do
    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:check, fn -> Relay.greeting_status() end)}
  end

  def handle_event("reset", _, %{assigns: %{status: :published, busy: false}} = socket) do
    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:reset, fn -> Relay.delete_greeting() end)}
  end

  def handle_event(event, _, socket) when event in ["check", "reset"],
    do: {:noreply, socket}

  @impl true
  def handle_async(:check, {:ok, {:ok, status}}, socket),
    do: {:noreply, assign(socket, status: status, busy: false)}

  def handle_async(:reset, {:ok, result}, socket) when result in [:ok, {:ok, :gone}],
    do: {:noreply, assign(socket, status: :default, busy: false)}

  def handle_async(_, {:ok, {:error, :not_configured}}, socket),
    do: {:noreply, assign(socket, status: :unconfigured, busy: false)}

  def handle_async(action, _failure, socket) do
    error =
      if action == :reset,
        do: "Could not reset the greeting. Check its status before trying again.",
        else: "The phone relay could not be reached. The greeting's status is unknown."

    {:noreply, assign(socket, status: :unavailable, busy: false, error: error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="ic-panel mx-auto w-full max-w-2xl p-5 sm:p-6" data-status={@status}>
      <div class="flex items-center gap-2">
        <.icon name="hero-phone" class="size-5 text-primary" />
        <h2 class="font-display text-lg font-bold">Outgoing greeting</h2>
      </div>
      <p class="mt-2 text-sm leading-relaxed text-base-content/65">
        An existing custom recording stays on your phone line until you reset it.
        The default greeting uses the phone service's synthesized voice.
      </p>
      <p id={"#{@id}-status"} class="mt-5 text-sm font-semibold" aria-live="polite">
        <%= case @status do %>
          <% :unchecked -> %>
            Greeting status has not been checked.
          <% :published -> %>
            Your custom greeting is published.
          <% :default -> %>
            Callers hear the default greeting.
          <% :unconfigured -> %>
            Configure the phone relay in Settings → Configuration → Credentials to check your greeting.
          <% :unavailable -> %>
            Greeting status is unavailable.
        <% end %>
      </p>
      <p :if={@error} id={"#{@id}-error"} role="alert" class="mt-2 text-sm text-error">{@error}</p>
      <div class="mt-5 flex flex-wrap gap-3">
        <button
          id={"#{@id}-check"}
          type="button"
          class="rounded-sm border border-primary bg-primary/15 px-4 py-2 text-sm font-semibold text-primary transition hover:bg-primary/25 disabled:opacity-50"
          phx-click="check"
          phx-target={@myself}
          disabled={@busy}
        >
          {if @busy, do: "Working…", else: "Check greeting"}
        </button>
        <button
          :if={@status == :published}
          id={"#{@id}-reset"}
          type="button"
          class="rounded-sm border border-base-content/25 px-4 py-2 text-sm font-semibold transition hover:bg-base-content/10 disabled:opacity-50"
          phx-click="reset"
          phx-target={@myself}
          disabled={@busy}
          data-claw-confirm="Callers will go back to the default synthesized voice. Reset the greeting?"
        >
          Use default greeting
        </button>
      </div>
    </section>
    """
  end
end
