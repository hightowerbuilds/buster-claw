defmodule BusterClawWeb.Appearance.Panels do
  @moduledoc """
  The Panel transparency control on Settings → Appearance (10-17): a slider for
  how see-through the Work Area's panels and sidebar are over the background,
  with a small preview. Its one event, `set_panel_transparency`, lands in
  `AppearanceLive`; the number and its rules are `BusterClaw.PanelTransparency`'s.
  """
  use BusterClawWeb, :html

  @doc """
  Panel transparency: one slider, 0 (solid) to 100 (only the blur), applied to
  the Work Area's panes and sidebar live (`BusterClaw.PanelTransparency`).

  The preview is a panel over the current background image when there is one,
  and over a striped field otherwise — a shader cannot be previewed cheaply, and
  stripes show what a fill hides as honestly as a picture does.
  """
  attr :value, :integer, required: true
  attr :image_url, :string, default: nil

  def panel_transparency_panel(assigns) do
    assigns = assign(assigns, :fill, BusterClaw.PanelTransparency.fills(assigns.value).panel)

    ~H"""
    <section id="panel-transparency" class="ic-panel space-y-2 p-4">
      <div class="flex items-baseline justify-between gap-2">
        <h2 class="ic-eyebrow">Panel transparency</h2>
        <span id="panel-transparency-value" class="font-mono text-xs tabular-nums">
          {@value}%
        </span>
      </div>

      <form id="panel-transparency-form" phx-change="set_panel_transparency">
        <input
          id="panel-transparency-range"
          type="range"
          name="transparency"
          min="0"
          max="100"
          step="1"
          value={@value}
          phx-debounce="60"
          aria-label="Panel transparency"
          aria-valuetext={"#{@value}% transparent"}
          class="w-full accent-primary"
        />
      </form>
      <div class="flex justify-between font-mono text-[0.625rem] uppercase tracking-wide text-base-content/45">
        <span>Solid</span>
        <span>Clear</span>
      </div>

      <div
        class="relative h-16 overflow-hidden rounded border border-base-content/15 bg-cover bg-center"
        style={preview_backdrop(@image_url)}
        aria-hidden="true"
      >
        <div
          class="absolute inset-2 flex items-center border border-base-content/20 px-3 font-mono text-xs backdrop-blur-[12px]"
          style={"background: color-mix(in oklab, var(--color-base-100) #{@fill}%, transparent)"}
        >
          A panel over your background
        </div>
      </div>

      <p class="text-[0.6875rem] leading-4 text-base-content/55">
        The Work Area's panels and sidebar, live. The blur stays at every setting, so
        text keeps an edge to read against.
      </p>
    </section>
    """
  end

  defp preview_backdrop(url) when is_binary(url), do: "background-image:url('#{url}')"

  defp preview_backdrop(_url),
    do:
      "background-image: repeating-linear-gradient(135deg, var(--color-primary) 0 10px, color-mix(in oklab, var(--color-base-content) 70%, transparent) 10px 20px)"
end
