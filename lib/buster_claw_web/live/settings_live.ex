defmodule BusterClawWeb.SettingsLive do
  @moduledoc """
  Settings → Configuration sub-tab. Holds the profile, onboarding progress, and
  the recovery key. The per-feature config surfaces (Google Workspace,
  Integrations, Security) are reachable via the Settings sub-tabs (see
  `BusterClawWeb.SettingsTabs`). Sits alongside the Appearance sub-tab
  (`BusterClawWeb.AppearanceLive`).
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Recovery
  alias BusterClaw.Setup

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:profile_name, Setup.profile_name())
     |> assign(:profile_org, Setup.profile_org())
     |> assign(:profile_note, nil)
     |> assign(:recovery_key, Recovery.recovery_key())
     |> assign(:recovery_revealed, false)
     |> assign(:restore_path, Recovery.restore_file_path())
     |> assign_status()}
  end

  @impl true
  def handle_event("save_profile", %{"name" => name, "org" => org}, socket) do
    Setup.put_profile(name, org)

    {:noreply,
     socket
     |> assign(:profile_name, String.trim(name))
     |> assign(:profile_org, String.trim(org))
     |> assign(:profile_note, "Saved.")
     |> assign_status()}
  end

  def handle_event("rerun_setup", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/setup")}
  end

  def handle_event("toggle_recovery", _params, socket) do
    {:noreply, update(socket, :recovery_revealed, &(not &1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="settings" class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:configuration} />

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Profile</h2>
          <form phx-submit="save_profile" class="grid gap-3 sm:grid-cols-2">
            <label class="block">
              <span class="ic-eyebrow">Your name</span>
              <input
                type="text"
                name="name"
                value={@profile_name}
                autocomplete="off"
                placeholder="Ada Lovelace"
                class="input mt-1 w-full"
              />
            </label>
            <label class="block">
              <span class="ic-eyebrow">Organization</span>
              <input
                type="text"
                name="org"
                value={@profile_org}
                autocomplete="off"
                placeholder="Analytical Engines Ltd."
                class="input mt-1 w-full"
              />
            </label>
            <button type="submit" class={["sm:col-span-2 sm:justify-self-start", button_outline()]}>
              Save profile
            </button>
          </form>
          <p
            :if={@profile_note}
            class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
          >
            {@profile_note}
          </p>
        </section>

        <section class="ic-panel space-y-4 p-6">
          <div class="flex items-center justify-between gap-4">
            <h2 class="ic-eyebrow">Setup progress</h2>
            <span class="font-mono text-xs text-base-content/60">
              {@status.completed} of {@status.total} complete
            </span>
          </div>
          <ul class="space-y-2 text-sm">
            <li :for={s <- @status.steps} class="flex items-center gap-2">
              <.icon
                name={if s.complete, do: "hero-check-circle-solid", else: "hero-minus-circle"}
                class={[
                  "size-5 shrink-0",
                  if(s.complete, do: "text-success", else: "text-base-content/40")
                ]}
              />
              <span class={if s.complete, do: "", else: "text-base-content/60"}>{s.label}</span>
            </li>
          </ul>
          <button type="button" phx-click="rerun_setup" class={button_outline()}>
            {if @status.complete?, do: "Re-run setup wizard", else: "Finish setup"}
          </button>
        </section>

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Recovery key</h2>
          <p class="text-sm text-base-content/70">
            This key encrypts every credential Buster Claw stores — Google tokens,
            integration secrets. It lives in your system keychain. Back it up to
            move Buster Claw to another machine; anyone with it can decrypt your
            data, so keep it somewhere safe.
          </p>
          <div :if={@recovery_key} class="space-y-3">
            <button type="button" phx-click="toggle_recovery" class={button_outline()}>
              {if @recovery_revealed, do: "Hide key", else: "Reveal key"}
            </button>
            <div :if={@recovery_revealed} class="space-y-3">
              <input
                type="text"
                readonly
                value={@recovery_key}
                aria-label="Recovery key"
                class="input w-full font-mono text-xs"
              />
              <p class="text-xs text-base-content/60">
                To restore on a new machine: save this value, then before first
                launch create a file named <code class="font-mono">RESTORE_SECRET_KEY</code>
                containing it at <code class="break-all font-mono">{@restore_path}</code>.
              </p>
            </div>
          </div>
          <p :if={is_nil(@recovery_key)} class="text-sm text-base-content/60">
            No recovery key is configured in this environment.
          </p>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp assign_status(socket), do: assign(socket, :status, Setup.status())

  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
