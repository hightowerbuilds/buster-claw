defmodule BusterClawWeb.OlympusLive do
  @moduledoc "The first Olympus environment: procedural peaks, static, and volumetric clouds."
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Mount Olympus")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} full_bleed>
      <section
        id="olympus"
        class="olympus"
        phx-hook="Olympus"
        phx-update="ignore"
        data-state="loading"
      >
        <canvas
          id="olympus-canvas"
          class="olympus-canvas"
          tabindex="0"
          aria-label="Mount Olympus in 3D. Drag to orbit, scroll to zoom. Keyboard: arrow keys to orbit, plus and minus to zoom."
        >
          A range of mountains made of television static rises through moving clouds.
        </canvas>
        <header class="olympus-header">
          <div class="olympus-brand">
            <.icon name="hero-sparkles" class="size-5" />
            <span>OLYMPUS</span>
          </div>
          <span class="olympus-chapter">WORLD 001 <span>/</span> THE ASCENT</span>
          <.link navigate={~p"/"} id="olympus-exit" class="olympus-exit" aria-label="Return to home">
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </header>
        <div class="olympus-heading">
          <p class="olympus-eyebrow">BETWEEN EARTH &amp; ETHER</p>
          <h1>Mount Olympus</h1>
          <p>A world taking shape above the clouds.</p>
        </div>
        <aside class="olympus-controls" aria-label="Scene controls">
          <div class="olympus-control-title">
            <span>ATMOSPHERE</span><span class="olympus-indicator"></span>
          </div>
          <label for="olympus-clouds">Cloud cover <output data-value="cloudCover">72%</output></label>
          <.input
            id="olympus-clouds"
            name="clouds"
            class="olympus-range"
            type="range"
            min="0"
            max="100"
            value="72"
            data-setting="cloudCover"
            aria-label="Cloud cover"
          />
          <label for="olympus-static">
            Signal noise <output data-value="interference">100%</output>
          </label>
          <.input
            id="olympus-static"
            name="static"
            class="olympus-range"
            type="range"
            min="0"
            max="100"
            value="100"
            data-setting="interference"
            aria-label="Signal noise"
          />
          <div class="olympus-buttons">
            <button id="olympus-orbit" type="button" data-action="orbit" aria-pressed="false">
              Auto orbit
            </button>
            <button id="olympus-reset" type="button" data-action="reset">Reset view</button>
          </div>
          <button id="olympus-pause" type="button" data-action="pause" aria-pressed="false">
            Pause motion
          </button>
        </aside>
        <footer class="olympus-footer">
          <span class="olympus-status" data-status role="status">FORMING THE WORLD…</span>
          <span class="olympus-hint">DRAG TO EXPLORE <span>·</span> SCROLL TO APPROACH</span>
          <span class="olympus-coordinate">40° 05′ N &nbsp; 22° 21′ E</span>
        </footer>
      </section>
    </Layouts.app>
    """
  end
end
