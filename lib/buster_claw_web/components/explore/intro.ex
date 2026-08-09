defmodule BusterClawWeb.Explore.Intro do
  @moduledoc """
  The Explore launcher: what Explore is for, the three-step Get Started
  collapsible, and a grid of square tiles — one per sub-tab, in rail order.

  A tile fires the same `select_explore_tab` event as the rail; the content
  lives on the tab it opens, so nothing here duplicates a panel.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explore.Shared

  alias BusterClawWeb.Explore.Registry

  # The opening tab is a launcher: what Explore is for, then a grid of square
  # tiles — one per sub-tab, in rail order. A tile fires the same
  # `select_explore_tab` event as the rail; the content lives on the tab it
  # opens, so nothing here duplicates a panel.
  def intro_panel(assigns) do
    assigns = assign(assigns, :tiles, Registry.tiles())

    ~H"""
    <div class="mx-auto flex max-w-3xl flex-col gap-6 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Explore</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Learn the machine.
        </h2>
      </div>

      <p class="text-sm leading-relaxed text-base-content/80">
        Buster Claw is a lot of surfaces — a browser the agent can drive, a phone
        line, Google Workspace, a live shader on this very page. Each square below
        opens a short tour of one of them: what it does, how to drive it yourself,
        and how to hand it to the agent. The grid grows as tutorials are written.
      </p>

      <%!-- The 3-step onboarding, moved here from the Settings Get Started tab
            (08-02) — setup before sightseeing. A native <details>, closed by
            default: returning users see one quiet row, first-run users open it
            once. State is the browser's, not LiveView's — a re-render that
            collapses it just restores the default. --%>
      <details id="explore-get-started" class="group ic-panel overflow-hidden">
        <summary class="ic-collapse-summary">
          <div>
            <p class="ic-eyebrow">Get started</p>
            <p class="mt-1 text-sm text-base-content/65">
              Three steps and you're talking to Buster Claw.
            </p>
          </div>
          <.icon
            name="hero-chevron-down"
            class="size-4 shrink-0 text-base-content/50 transition group-open:rotate-180"
          />
        </summary>

        <ol class="flex flex-col gap-4 border-t-2 border-base-content/20 px-5 py-5">
          <li class="flex gap-3">
            <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
              1
            </span>
            <div class="min-w-0">
              <h3 class="font-semibold">Install a supported agent CLI</h3>
              <p class="mt-0.5 text-sm text-base-content/65">
                Buster Claw has no built-in AI — it drives an agent CLI you install
                and sign in to. Claude Code is the recommended one;
                Chat and unattended work can also use Codex or OpenCode. On macOS,
                Homebrew is one way to install Claude Code:
                <.copy_command command="brew install --cask claude-code" />. Then sign
                in with <span class="font-mono">claude</span>
                in a terminal.
              </p>
            </div>
          </li>

          <li class="flex gap-3">
            <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
              2
            </span>
            <div class="min-w-0">
              <h3 class="font-semibold">Chat with Buster Claw</h3>
              <p class="mt-0.5 text-sm text-base-content/65">
                Use the Chat sub-tab — first in this same row. Ask it to triage your
                inbox, draft a reply, or look something up — it runs your selected
                agent CLI headlessly, no terminal needed.
              </p>
            </div>
          </li>

          <li class="flex gap-3">
            <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
              3
            </span>
            <div class="min-w-0">
              <h3 class="font-semibold">Set up communications</h3>
              <p class="mt-0.5 text-sm text-base-content/65">
                Connect Google Workspace in <.link
                  navigate="/settings"
                  class="font-semibold text-primary hover:opacity-80"
                >
                  Configuration
                </.link>, then list your trusted senders in Contacts — the corner widget on
                this screen. Use the bundled Connect button when this build offers
                it; otherwise Advanced setup accepts your own OAuth client. Mail from
                other senders is still synced and archived in the Library, but only
                trusted senders become Dispatch work. When you're ready, give your
                agent its own phone line on the
                <.link navigate="/phone" class="font-semibold text-primary hover:opacity-80">
                  Phone
                </.link>
                tab.
              </p>
            </div>
          </li>
        </ol>
      </details>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        <button
          :for={tile <- @tiles}
          type="button"
          phx-click="select_explore_tab"
          phx-value-tab={tile.key}
          class="ic-panel flex aspect-square flex-col justify-between p-4 text-left transition hover:-translate-y-0.5 hover:border-primary"
        >
          <p class="ic-eyebrow">{tile.eyebrow}</p>
          <div class="flex flex-col gap-1.5">
            <p class="font-display text-sm font-black uppercase tracking-wide">
              {tile.label}
            </p>
            <p class="text-xs leading-relaxed text-base-content/65">{tile.blurb}</p>
          </div>
        </button>
      </div>
    </div>
    """
  end
end
