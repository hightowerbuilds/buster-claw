defmodule BusterClawWeb.DutyLive do
  @moduledoc """
  The on-duty workspace: connection readiness, live activity, and the stop control.
  Existing activity records remain in their original surfaces. Standing down
  latches the brake before stopping the shift; an in-flight run still finishes.

  Renders when idle too (THREE_DOORS Phase 2). Until 09-13 this page bounced
  home the moment no shift was active, so it could only be seen once a shift had
  already been started from a terminal. Idle, it shows the same readiness cards
  and the Go on duty control, so what a shift needs is visible before one runs.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.{Dispatch, Duty, DutyActivity, Google, Journal, Orchestration, Sentinel}
  alias BusterClaw.Telephony
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
    case Duty.stand_down(:duty_page) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stood down. No new work will start; a run in progress finishes.")
         |> refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not stand down. Run ./buster-claw off-duty.")}
    end
  end

  def handle_event("go_on_duty", _params, socket) do
    case Duty.go_on_duty(:duty_page, agent_cli_opts()) do
      {:ok, _shift} ->
        {:noreply, refresh(socket)}

      {:error, {:not_ready, [blocker | _]}} ->
        {:noreply, socket |> put_flash(:error, "#{blocker.label} first.") |> refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start a shift.")}
    end
  end

  defp refresh(socket) do
    accounts = Google.list_account_summaries()

    socket =
      socket
      |> assign(:phone_ready, Relay.configured?())
      |> assign(:email_ready, Enum.any?(accounts, &Duty.account_ready?/1))
      |> assign(
        :email_label,
        accounts |> Enum.filter(&Duty.account_ready?/1) |> Enum.map_join(", ", & &1.email)
      )

    case Orchestration.active_shift() do
      nil ->
        socket
        |> assign(:shift, nil)
        |> assign(:readiness, Duty.readiness(agent_cli_opts()))
        |> assign(:trusted_count, length(BusterClaw.TrustedSenders.list_entries()))
        |> stream(:activity, [], reset: true)

      shift ->
        socket
        |> assign(:shift, shift)
        |> assign(:readiness, %{ready?: true, blockers: []})
        |> assign(:trusted_count, length(BusterClaw.TrustedSenders.list_entries()))
        |> stream(:activity, DutyActivity.list(shift), reset: true)
    end
  end

  # Same seam `DutyDockLive` honours: the suite pins `:agent_cli` in app env
  # because the machine running it may or may not have `claude` on PATH.
  defp agent_cli_opts do
    case Application.get_env(:buster_claw, :agent_cli) do
      {_backend, _path} -> [agent_cli?: true]
      _ -> []
    end
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
