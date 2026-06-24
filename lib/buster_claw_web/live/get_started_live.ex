defmodule BusterClawWeb.GetStartedLive do
  @moduledoc """
  Onboarding guide, surfaced as a Settings sub-tab (moved out of the home header
  corner widget). The quick-chat starters dispatch a message to the home
  conversation and navigate there, so the run shows up in the chat panel.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations

  @quick_prompts [
    "Please read through the introduction and BusterClawWorkspace and give me an explanation.",
    "Explain Buster Claw's Sentinel security layer — what it audits, the safe vs restricted trust tiers, and the gate on irreversible actions. Then exemplify it: run one safe command and one restricted command through the ./buster-claw CLI, show how each is recorded on the audit feed, and point me to the Security tab to watch it live.",
    "Give me an overview of everything you can do across my Google Workspace. Run `./buster-claw commands` to read your full catalog, then summarize the Google capabilities grouped by service — Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, and Tasks — noting for each which actions are read-only (safe) versus those that change or delete data and need confirmation.",
    "Check my mail and tell me what needs a reply.",
    "What can you do? Show me a few things to try."
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Get Started")
     |> assign(:quick_prompts, @quick_prompts)}
  end

  # The quick-chat starters belong with the chat: send to the home conversation,
  # then navigate to the home page where the chat panel shows the run.
  @impl true
  def handle_event("quick_chat", %{"prompt" => prompt}, socket) do
    try do
      _ = Chat.send_message(active_conv_id(), prompt)
    catch
      # Chat backend not running — still take them home; the page surfaces it.
      :exit, _reason -> :ok
    end

    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  # Target the same conversation the home page shows (its most-recent one).
  defp active_conv_id do
    case Conversations.list() do
      [conv | _] -> conv.id
      [] -> Chat.default_conv_id()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:get_started} />

        <div id="get-started" class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Get Started</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Get Started
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Three steps and you're talking to Buster Claw (Google Workspace already connected).
            </p>
          </header>

          <ol class="flex flex-col gap-4 px-5 py-5">
            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                1
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Add your trusted contacts</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  On the Home screen's Contacts tab, list the senders Buster Claw may read and
                  reply to. Mail from anyone else is ignored.
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
                  Use the chat on the Home screen. Ask it to triage your inbox, draft a reply, or
                  look something up — it runs headless Claude for you, no terminal needed.
                </p>
              </div>
            </li>
          </ol>
        </div>

        <div id="get-started-quick-chat" class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Quick chat</p>
            <p class="mt-1 text-sm text-base-content/65">
              Click a starter and we'll run it in the Home chat.
            </p>
          </header>

          <div class="flex flex-col gap-2 px-5 py-5">
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
        </div>
      </section>
    </Layouts.app>
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
end
