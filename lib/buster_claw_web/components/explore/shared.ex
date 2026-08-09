defmodule BusterClawWeb.Explore.Shared do
  @moduledoc """
  The leaf components the Explore tutorials are built from — a worked cycle, the
  prompt the user types, an inline shell command with a copy button, and an
  outbound link.

  Imported by the panel modules rather than aliased, so a tutorial writes
  `<.prompt text="…" />` exactly as it did when every panel lived in one file.

  ## The demo contract

  `example/1`'s four fact attrs — `needs`, `touches`, `confirm`, `result` — are
  **required**, which is the whole point of them. A worked example that does not
  say what it needs, what it touches, where the stop is, and what happens when
  the dependency is missing is the failure mode this component exists to
  prevent: prose that reads like a promise. Required attrs make that a compile
  error rather than an editorial oversight nobody catches. Answering "nothing —
  this is a read" is a fine answer; omitting the row is not, and is not
  possible.

  `prompt/1` carries the two safe actions: **Copy prompt** (the global
  `data-terminal-command-copy` listener in `lib/globals.js` — generic, it copies
  whatever the attribute holds) and **Try in Chat**, which prefills the home
  composer and never submits. Set `try_in_chat={false}` when the prompt is not
  something you would type into chat — the GWS unattended cycle's prompt is an
  *email*, and offering to paste it into the composer would teach the wrong
  thing about how that path is triggered.
  """
  use BusterClawWeb, :html

  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :want, :string, required: true

  attr :needs, :string,
    required: true,
    doc: "Prerequisites: connection, desktop app, current tab, account, enablement."

  attr :touches, :string,
    required: true,
    doc: "What it reads or changes — the side effects, named before the prompt."

  attr :confirm, :string,
    required: true,
    doc: "Where the stop is: a policy gate, a command argument, a UI card, or none."

  attr :result, :string,
    required: true,
    doc: "Where the artifact/receipt lands, and what you see when a dependency is missing."

  slot :inner_block, required: true

  # A worked cycle. The facts sit between the header and the body deliberately:
  # the roadmap's rule is "name the side effects *before* the prompt", and the
  # prompt is the first thing in every inner_block.
  def example(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 border-l-2 border-base-content/20 pl-4">
      <div>
        <p class="ic-eyebrow">Cycle {@n}</p>
        <h3 class="mt-1 font-display text-base font-black uppercase tracking-wide">
          {@title}
        </h3>
        <p class="mt-1 text-sm italic text-base-content/60">{@want}</p>
      </div>

      <dl
        data-demo-facts
        class="grid grid-cols-[5.25rem_1fr] gap-x-3 gap-y-1.5 border-y border-base-content/15 py-2.5 text-xs leading-relaxed"
      >
        <dt data-demo-needs class="ic-eyebrow">Needs</dt>
        <dd class="text-base-content/70">{@needs}</dd>
        <dt data-demo-touches class="ic-eyebrow">Touches</dt>
        <dd class="text-base-content/70">{@touches}</dd>
        <dt data-demo-confirm class="ic-eyebrow">Stop</dt>
        <dd class="text-base-content/70">{@confirm}</dd>
        <dt data-demo-result class="ic-eyebrow">Result</dt>
        <dd class="text-base-content/70">{@result}</dd>
      </dl>

      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :text, :string, required: true
  attr :label, :string, default: "You type"

  attr :try_in_chat, :boolean,
    default: true,
    doc: "False when the prompt is not chat input (an email, a spoken message, a terminal line)."

  # What the user literally says — set apart so the eye can skim a tutorial
  # prompt-first, which is how people actually read these. Both actions are
  # safe by construction: one writes the clipboard, the other writes the
  # composer. Neither submits, so opening a tutorial can never run a mutation.
  def prompt(assigns) do
    ~H"""
    <%!-- data-demo-prompt is the countable anchor: the visible "Copy prompt"
          string also appears in that button's aria-label, so a test counting the
          text counts every prompt twice. --%>
    <figure data-demo-prompt class="ic-panel flex flex-col gap-2 p-3">
      <figcaption class="ic-eyebrow">{@label}</figcaption>
      <blockquote class="font-mono text-sm leading-relaxed">“{@text}”</blockquote>
      <div class="flex flex-wrap items-center gap-1.5">
        <button
          type="button"
          data-terminal-command-copy={@text}
          aria-label="Copy prompt to the clipboard"
          class="inline-flex items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
        >
          <.icon name="hero-clipboard-document" class="size-3" />
          <span data-terminal-command-copy-label>Copy prompt</span>
        </button>
        <button
          :if={@try_in_chat}
          type="button"
          phx-click="explore_try_in_chat"
          phx-value-text={@text}
          data-demo-try-in-chat
          aria-label="Put this prompt in the Chat composer without sending it"
          class="inline-flex items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-3" /> Try in Chat
        </button>
        <span :if={@try_in_chat} class="font-mono text-[0.62rem] text-base-content/40">
          prefills the composer — you press send
        </span>
      </div>
    </figure>
    """
  end

  attr :command, :string, required: true

  # Block-level shell command: wraps rather than scrolling (long commands must
  # never demand horizontal scrolling — operator, 08-02), full-contrast mono on
  # a bordered field, copy button via the global data-terminal-command-copy
  # listener in globals.js.
  def copy_command(assigns) do
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

  attr :url, :string, required: true
  attr :label, :string, required: true

  # External sites open in the app's own browser tab — this app has one.
  def external_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/browse?#{[url: @url]}"}
      class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
    >
      <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
      {@label}
    </.link>
    """
  end
end
