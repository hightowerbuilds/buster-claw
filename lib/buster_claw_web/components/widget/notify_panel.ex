defmodule BusterClawWeb.Widget.NotifyPanel do
  @moduledoc """
  The corner widget's **Notify** tab: a kind-aware creation form over the
  upcoming notifications of that kind, plus the fired-notification modal.

  `notify_modal/1` is the one function here with a caller outside the widget —
  `NotifyLive` renders it for a notification that has fired. It lives with the
  panel that creates them rather than with the card that hosts the tab.

  Markup only; `notify_create`, `notify_snooze`, `notify_dismiss` and
  `notify_kind` are handled by `StatusLive`.

  Split out of `HomeWidget` on 08-15 (`WIDGET_BACKGROUND_ROADMAP` Phase 0).
  """
  use BusterClawWeb, :html

  # Notify: a kind-aware creation form over the upcoming notifications of that
  # kind. The segmented row does double duty — it picks what the form arms
  # (Timer: label + minutes; Alarm: optional label + wall-clock time; Reminder:
  # label + wall-clock time — both wall-clock kinds arm the next local
  # occurrence) AND filters the right column, so the shader countdown and list
  # show only the selected kind. `select_widget_tab`, `notify_kind`,
  # `notify_create`, `notify_snooze`, and `notify_dismiss` are handled by
  # StatusLive. The relative "fires in" label re-renders on every change; the
  # live per-second countdown arrives with the digit shader (Phase 2).
  attr :notifications, :list, required: true
  attr :form, :any, required: true
  attr :kind, :string, required: true

  def notify_panel(assigns) do
    assigns =
      assign(
        assigns,
        :kind_notifications,
        Enum.filter(assigns.notifications, &(&1.kind == assigns.kind))
      )

    ~H"""
    <section id="home-notify-panel" class="ic-panel grid h-full grid-cols-5">
      <%!-- Left 3/5: notifier creation. --%>
      <div class="col-span-3 flex min-h-0 flex-col border-r border-base-content/15 px-3 py-3">
        <div
          role="radiogroup"
          aria-label="Notification kind"
          class="mb-1.5 flex gap-1"
        >
          <button
            :for={{key, text} <- [{"timer", "Timer"}, {"alarm", "Alarm"}, {"reminder", "Reminder"}]}
            type="button"
            role="radio"
            aria-checked={to_string(@kind == key)}
            phx-click="notify_kind"
            phx-value-kind={key}
            class={[
              "border px-2 py-1 font-mono text-[0.6875rem] font-bold uppercase tracking-widest transition",
              if(@kind == key,
                do: "border-primary text-primary",
                else: "border-base-content/25 text-base-content/55 hover:text-base-content"
              )
            ]}
          >
            {text}
          </button>
        </div>

        <.form for={@form} id="notify-form" phx-submit="notify_create" class="flex flex-col gap-1.5">
          <input type="hidden" name="notify[kind]" value={@kind} />
          <input
            type="text"
            name="notify[label]"
            value={@form[:label].value}
            required={@kind != "alarm"}
            placeholder={notify_label_placeholder(@kind)}
            autocomplete="off"
            class="min-w-0 border-2 border-base-content/25 bg-base-100 px-2.5 py-1.5 font-mono text-[0.8125rem]"
          />
          <div class="flex gap-1.5">
            <input
              :if={@kind == "timer"}
              type="number"
              name="notify[minutes]"
              value={@form[:minutes].value}
              min="1"
              required
              placeholder="min"
              class="min-w-0 flex-1 border-2 border-base-content/25 bg-base-100 px-2.5 py-1.5 font-mono text-[0.8125rem]"
            />
            <input
              :if={@kind in ["alarm", "reminder"]}
              type="time"
              name="notify[at]"
              value={@form[:at].value}
              required
              class="min-w-0 flex-1 border-2 border-base-content/25 bg-base-100 px-2.5 py-1.5 font-mono text-[0.8125rem]"
            />
            <button
              type="submit"
              class="shrink-0 border-2 border-primary px-2.5 py-1.5 font-display text-[0.6875rem] font-bold uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
            >
              Set
            </button>
          </div>
          <p :if={@form.errors != []} class="font-mono text-[0.6875rem] text-primary">
            {form_error_text(@form)}
          </p>
        </.form>
      </div>

      <%!-- Right 2/5: the selected kind only — soonest as a shader countdown, then the list. --%>
      <div class="col-span-2 flex min-h-0 flex-col">
        {if @kind_notifications != [], do: notify_hero(%{soonest: hd(@kind_notifications)})}

        <ul class="min-h-0 flex-1 divide-y divide-base-content/10 overflow-auto">
          <li :for={notification <- @kind_notifications} class="px-2 py-2">
            <div class="truncate font-mono text-xs text-base-content">{notification.label}</div>
            <div class="font-mono text-[0.625rem] uppercase tracking-wide text-base-content/55">
              {kind_label(notification.kind)} · {fires_in_label(notification.fire_at)}
            </div>
            <div class="mt-1 flex gap-1">
              <button
                type="button"
                phx-click="notify_snooze"
                phx-value-id={notification.id}
                class="border border-base-content/25 px-1.5 py-0.5 font-mono text-[0.625rem] uppercase text-base-content/70 transition hover:border-base-content"
              >
                Snooze
              </button>
              <button
                type="button"
                phx-click="notify_dismiss"
                phx-value-id={notification.id}
                class="border border-error/40 px-1.5 py-0.5 font-mono text-[0.625rem] uppercase text-error transition hover:border-error"
              >
                Dismiss
              </button>
            </div>
          </li>
          <li
            :if={@kind_notifications == []}
            class="px-2 py-8 text-center font-mono text-[0.625rem] uppercase tracking-widest text-base-content/45"
          >
            No {kind_label(@kind) |> String.downcase()}s set
          </li>
        </ul>
      </div>
    </section>
    """
  end

  @doc """
  The fired-notification modal: a big seven-segment `00:00` (the ShaderTimer,
  fed a past `fire_at`, clamps to zero) over the label, with Snooze / Dismiss.
  Rendered by StatusLive from the head of its fired queue; the events
  (`notify_ack`, `notify_ack_snooze`) are handled there.
  """
  attr :notification, :map, required: true

  def notify_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-[120] grid place-items-center bg-black/60 p-4"
      role="alertdialog"
      aria-modal="true"
    >
      <div class="ic-panel w-full max-w-sm border-2 border-base-content bg-base-100 p-5 text-base-content shadow-lg">
        <div class="font-display text-xs font-bold uppercase tracking-widest text-primary">
          {kind_label(@notification.kind)} · time's up
        </div>
        <div class="relative mt-3 h-20 w-full overflow-hidden border border-base-content/20 bg-base-100">
          <div
            id={"notify-modal-#{@notification.id}"}
            phx-hook="ShaderTimer"
            phx-update="ignore"
            data-fire-at={DateTime.to_unix(@notification.fire_at)}
            class="absolute inset-0"
          >
            <canvas data-timer-canvas class="absolute inset-0 h-full w-full"></canvas>
            <div
              data-timer-text
              class="pointer-events-none absolute inset-0 grid place-items-center font-mono text-4xl font-bold tabular-nums tracking-widest text-base-content"
            >
              00:00
            </div>
          </div>
        </div>
        <p class="mt-3 truncate text-center font-mono text-sm">{@notification.label}</p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            phx-click="notify_ack_snooze"
            phx-value-id={@notification.id}
            class="border-2 border-base-content px-3 py-1 font-display text-xs font-bold uppercase tracking-wide transition hover:bg-base-200"
          >
            Snooze 5m
          </button>
          <button
            type="button"
            phx-click="notify_ack"
            phx-value-id={@notification.id}
            class="border-2 border-primary bg-primary px-3 py-1 font-display text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-90"
          >
            Dismiss
          </button>
        </div>
      </div>
    </div>
    """
  end

  # The soonest upcoming notification as a big seven-segment countdown. The shader
  # (ShaderTimer hook) owns the live tick from `data-fire-at`; the text node is the
  # placeholder before boot and the fallback when WebGPU is unavailable. The id
  # carries fire-at, so when the soonest changes the element is replaced and the
  # hook remounts on the new target.
  attr :soonest, :map, required: true

  def notify_hero(assigns) do
    ~H"""
    <div class="shrink-0 border-b border-base-content/15 px-3 py-3">
      <div
        id={"notify-countdown-#{@soonest.id}-#{DateTime.to_unix(@soonest.fire_at)}"}
        phx-hook="ShaderTimer"
        phx-update="ignore"
        data-fire-at={DateTime.to_unix(@soonest.fire_at)}
        class="relative h-16 w-full overflow-hidden border border-base-content/20 bg-base-100"
      >
        <canvas data-timer-canvas class="absolute inset-0 h-full w-full"></canvas>
        <div
          data-timer-text
          class="pointer-events-none absolute inset-0 grid place-items-center font-mono text-3xl font-bold tabular-nums tracking-widest text-base-content"
        >
          --:--
        </div>
      </div>
      <div class="mt-1 truncate text-center font-mono text-[0.625rem] uppercase tracking-widest text-base-content/60">
        {kind_label(@soonest.kind)} · {@soonest.label}
      </div>
    </div>
    """
  end

  def kind_label("timer"), do: "Timer"
  def kind_label("alarm"), do: "Alarm"
  def kind_label("reminder"), do: "Reminder"
  def kind_label(other), do: other

  def notify_label_placeholder("alarm"), do: "Label (optional)"
  def notify_label_placeholder("reminder"), do: "Label, e.g. Stretch"
  def notify_label_placeholder(_timer), do: "Label, e.g. Tea"

  # A coarse, timezone-free "fires in" label. Placeholder for the live shader
  # countdown; re-computed each render, so it tracks reloads/changes, not seconds.
  def fires_in_label(fire_at) do
    seconds = DateTime.diff(fire_at, DateTime.utc_now())

    cond do
      seconds <= 0 -> "now"
      seconds < 60 -> "in #{seconds}s"
      seconds < 3600 -> "in #{div(seconds, 60)}m"
      seconds < 86_400 -> "in #{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
      true -> "in #{div(seconds, 86_400)}d"
    end
  end

  def form_error_text(form) do
    Enum.map_join(form.errors, "; ", fn {_field, {message, _opts}} -> message end)
  end
end
