defmodule BusterClawWeb.ChartBuilderPanel do
  @moduledoc "The Chart Build preview pane; conversation state stays in TradingLive."
  use BusterClawWeb, :html

  attr :charts, :list, required: true
  attr :zoomed, :any, default: nil

  def chart_preview(assigns) do
    assigns = assign(assigns, :latest, List.last(assigns.charts))

    ~H"""
    <section
      id="chartbuild-preview"
      class="flex min-h-0 flex-[1.1] flex-col overflow-hidden border-2 border-secondary/35 bg-base-100"
    >
      <header class="flex shrink-0 items-center justify-between gap-3 border-b-2 border-base-content/15 bg-secondary/5 px-4 py-2">
        <div>
          <p class="font-mono text-[0.62rem] font-black uppercase tracking-[0.18em] text-secondary">
            Chart preview
          </p>
          <p class="font-mono text-[0.58rem] uppercase tracking-wide text-base-content/45">
            Drawn by AI · not computed
          </p>
        </div>
        <button
          :if={@latest}
          id="chartbuild-expand"
          type="button"
          phx-click="zoom_svg"
          phx-value-id={@latest && @latest.id}
          class="inline-flex items-center gap-1.5 rounded-sm border-2 border-secondary/40 px-2.5 py-1 font-mono text-[0.65rem] font-bold uppercase tracking-wide text-secondary transition hover:bg-secondary hover:text-secondary-content"
        >
          <.icon name="hero-arrows-pointing-out" class="size-3.5" /> Expand
        </button>
      </header>

      <button
        :if={@latest && is_nil(@zoomed)}
        id="chartbuild-latest"
        type="button"
        phx-click="zoom_svg"
        phx-value-id={@latest && @latest.id}
        aria-label="Open latest chart full screen"
        class="grid min-h-0 flex-1 cursor-zoom-in place-items-center overflow-auto p-4 text-left"
      >
        <div class="chartbuild-svg w-full max-w-5xl">
          {Phoenix.HTML.raw(@latest && @latest.svg)}
        </div>
      </button>

      <div
        :if={!@latest}
        id="chartbuild-empty"
        class="grid min-h-48 flex-1 place-items-center p-6 text-center"
      >
        <div class="max-w-md">
          <.icon name="hero-chart-bar-square" class="mx-auto size-9 text-secondary/65" />
          <p class="mt-3 font-mono text-xs font-black uppercase tracking-wide">Describe a chart</p>
          <p class="mt-2 text-sm leading-relaxed text-base-content/55">
            Ask below using pasted numbers or the cached portfolio data. Your newest chart will
            appear here; earlier versions remain in the conversation.
          </p>
        </div>
      </div>

      <footer
        :if={length(@charts) > 1}
        class="shrink-0 border-t border-base-content/15 px-4 py-1.5 text-right font-mono text-[0.6rem] uppercase tracking-wide text-base-content/45"
      >
        Version {length(@charts)} · open any earlier chart from its message
      </footer>
    </section>
    """
  end
end
