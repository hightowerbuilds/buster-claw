defmodule BusterClawWeb.DutyLive do
  @moduledoc """
  The on-duty workspace: connection readiness, live activity, and the stop control.
  Existing activity records remain in their original surfaces. Standing down
  latches the brake before stopping the shift; an in-flight run still finishes.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.{Dispatch, DutyActivity, Google, Journal, Orchestration, Sentinel, Telephony}
  alias BusterClaw.Telephony.Relay

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Orchestration.subscribe()
      Dispatch.subscribe()
      Sentinel.subscribe()
      Telephony.subscribe()
      Google.subscribe()
      Journal.subscribe()
    end

    {:ok, socket |> assign(:page_title, "On duty") |> refresh()}
  end

  @impl true
  def handle_info({:journal_appended, _day}, socket) do
    send_update(BusterClawWeb.ActivityComponent, id: "duty-minutes", refresh: true)
    {:noreply, refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("stand_down", _params, socket) do
    case Orchestration.stand_down("stood down from the duty tab") do
      {:ok, _result} ->
        Sentinel.observe(:security_block, "Shift stopped by the operator (duty tab)", %{})

        {:noreply,
         socket
         |> put_flash(:info, "Stood down. No new work will start; a run in progress finishes.")
         |> push_navigate(to: ~p"/")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not stand down. Run ./buster-claw off-duty.")}
    end
  end

  defp refresh(socket) do
    case Orchestration.active_shift() do
      nil ->
        socket |> assign(:shift, nil) |> push_navigate(to: ~p"/")

      shift ->
        accounts = Google.list_account_summaries()

        socket
        |> assign(:shift, shift)
        |> assign(:phone_ready, Relay.configured?())
        |> assign(:email_ready, Enum.any?(accounts, &email_ready?/1))
        |> assign(
          :email_label,
          accounts |> Enum.filter(&email_ready?/1) |> Enum.map_join(", ", & &1.email)
        )
        |> stream(:activity, DutyActivity.list(shift), reset: true)
    end
  end

  defp email_ready?(account) do
    account.enabled and account.has_refresh_token and not account.reconnect_needed
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :ready, :boolean, required: true
  attr :detail, :string, required: true
  attr :href, :string, required: true

  defp channel(assigns) do
    ~H"""
    <section id={@id} class="rounded border border-base-content/10 p-3" data-ready={to_string(@ready)}>
      <div class="flex items-center gap-2">
        <.icon name={@icon} class="size-3.5 text-base-content/45" />
        <h2 class="text-xs font-medium">{@label}</h2>
        <span class="ml-auto text-[10px] text-base-content/45">
          {if @ready, do: "Configured", else: "Setup needed"}
        </span>
      </div>
      <p class="mt-2 break-words text-[11px] leading-relaxed text-base-content/50">{@detail}</p>
      <.link
        navigate={@href}
        class="mt-2 inline-block text-[11px] text-base-content/60 underline-offset-4 transition hover:text-primary hover:underline"
      >
        Open {@label}
      </.link>
    </section>
    """
  end
end
