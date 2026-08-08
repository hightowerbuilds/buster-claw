defmodule BusterClawWeb.Explore.Shared do
  @moduledoc """
  The four leaf components the Explore tutorials are built from — a worked
  cycle, the prompt the user types, an inline shell command with a copy button,
  and an outbound link.

  Imported by the panel modules rather than aliased, so a tutorial writes
  `<.prompt text="…" />` exactly as it did when every panel lived in one file.
  """
  use BusterClawWeb, :html

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
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :text, :string, required: true
  attr :label, :string, default: "You type"

  # What the user literally says — set apart so the eye can skim a tutorial
  # prompt-first, which is how people actually read these.
  def prompt(assigns) do
    ~H"""
    <figure class="ic-panel flex flex-col gap-1 p-3">
      <figcaption class="ic-eyebrow">{@label}</figcaption>
      <blockquote class="font-mono text-sm leading-relaxed">“{@text}”</blockquote>
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
