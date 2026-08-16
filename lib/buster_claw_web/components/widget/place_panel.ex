defmodule BusterClawWeb.Widget.PlacePanel do
  @moduledoc """
  The corner widget's **Time & Place** tab: the `daycycle` shader with the
  analog clock and current conditions floating over it in glass.

  Split out of `HomeWidget` on 08-15 (`WIDGET_BACKGROUND_ROADMAP` Phase 0), and
  this is the panel that roadmap is *for*: its shader is hardcoded here, and
  making it selectable is what the FROZEN cap on the old file was blocking.
  Nothing about the shader changed in this move — that is Phase 1.
  """
  use BusterClawWeb, :html

  # Time & Place: the daycycle shader (sun/moon arc, clouds, wind, birds by
  # day, stars by night — driven by the machine's local clock via u.lens.x)
  # fills the panel; the analog clock and current conditions float above it in
  # glass. The card's ic-scanlines overlay stays on top of everything.
  attr :weather, :any, required: true
  attr :form, :boolean, required: true
  attr :bg, :map, required: true

  def place_panel(assigns) do
    ~H"""
    <section id="home-place-panel" class="relative h-full overflow-hidden">
      <%!-- Was a hardcoded `daycycle` mount with a literal `data-daylight`. Both
            are the surface's choice now (WIDGET_BACKGROUND Phase 2): the shader
            comes from Appearance, and the clock flag is derived from the shader
            by `ShaderCanvas` so no mount can forget it.

            An image paints as a sibling div, the way the homepage does it — the
            terminal instead styles its host element, which is why there is no
            single `background/1` component to share here. `ic-shader-fill` is
            `absolute; inset: 0`, so both kinds fill the panel identically. --%>
      <div
        :if={@bg.mode == "image"}
        class="ic-shader-fill"
        style={"background-image:url('#{@bg.image_url}');background-size:cover;background-position:center;"}
        aria-hidden="true"
      >
      </div>
      <BusterClawWeb.ShaderCanvas.shader_canvas bg={@bg} prefix="widget" />

      <%!-- Clock and conditions side by side, transparent so the sky reads through. --%>
      <div class="relative z-10 flex h-full gap-2 p-3">
        <%!-- The clock: hook-owned motion, frozen markup. --%>
        <div
          id="home-clock"
          phx-hook="Clock"
          phx-update="ignore"
          class="flex min-h-0 min-w-0 flex-1 flex-col items-center justify-center gap-1 p-1"
        >
          <svg
            viewBox="0 0 200 200"
            class="min-h-0 w-full max-w-36 flex-1"
            role="img"
            aria-label="Analog clock"
          >
            <circle
              cx="100"
              cy="100"
              r="96"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              class="text-base-content/25"
            />
            <%= for tick <- 0..59 do %>
              <line
                x1="100"
                y1={if rem(tick, 5) == 0, do: "12", else: "8"}
                x2="100"
                y2={if rem(tick, 5) == 0, do: "22", else: "14"}
                stroke="currentColor"
                stroke-width={if rem(tick, 5) == 0, do: "3", else: "1"}
                class={if rem(tick, 5) == 0, do: "text-base-content/70", else: "text-base-content/30"}
                transform={"rotate(#{tick * 6} 100 100)"}
              />
            <% end %>
            <g data-hand="hour">
              <line
                x1="100"
                y1="100"
                x2="100"
                y2="52"
                stroke="currentColor"
                stroke-width="5"
                stroke-linecap="round"
                class="text-base-content"
              />
            </g>
            <g data-hand="minute">
              <line
                x1="100"
                y1="100"
                x2="100"
                y2="32"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
                class="text-base-content/80"
              />
            </g>
            <g data-hand="second">
              <line
                x1="100"
                y1="112"
                x2="100"
                y2="26"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                class="text-primary"
              />
            </g>
            <circle cx="100" cy="100" r="4" class="fill-primary" />
          </svg>
          <div class="text-center">
            <div data-clock-digital class="font-mono text-lg font-bold tabular-nums tracking-wide">
              --:--:--
            </div>
            <div
              data-clock-date
              class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/55"
            >
              &nbsp;
            </div>
          </div>
        </div>

        <%!-- The place: current conditions, or the location form. --%>
        <div class="flex min-h-0 min-w-0 flex-1 flex-col justify-center p-1">
          <form :if={@form} phx-submit="set_weather_location" class="flex flex-col gap-1.5">
            <label class="font-mono text-[0.625rem] font-bold uppercase tracking-widest text-base-content/55">
              Where are you?
            </label>
            <div class="flex gap-1.5">
              <input
                type="text"
                name="query"
                required
                placeholder="City, e.g. Portland"
                autocomplete="off"
                class="min-w-0 flex-1 border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-xs"
              />
              <button
                type="submit"
                class="shrink-0 border-2 border-primary px-2 py-1 font-display text-[0.625rem] font-bold uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
              >
                Set
              </button>
            </div>
            <p :if={@weather == {:error, :not_found}} class="font-mono text-[0.625rem] text-primary">
              No place by that name — try adding a state or country.
            </p>
          </form>

          <div
            :if={!@form and @weather == :loading}
            class="py-1 text-center font-mono text-[0.625rem] uppercase tracking-widest text-base-content/50"
          >
            Checking the sky…
          </div>

          <div
            :if={!@form and match?({:error, _}, @weather)}
            class="flex items-center justify-between py-1"
          >
            <span class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/55">
              Weather unavailable
            </span>
            <button
              type="button"
              phx-click="edit_weather_location"
              class="font-mono text-[0.625rem] uppercase tracking-wide text-primary underline underline-offset-2"
            >
              Set location
            </button>
          </div>

          <div :if={!@form and is_map(@weather)} class="flex flex-col items-center gap-1 text-center">
            <span class="max-w-full truncate font-display text-[0.625rem] font-bold uppercase tracking-widest text-base-content/70">
              {@weather.location}
            </span>
            <span class="font-display text-4xl font-black tabular-nums leading-none">
              {@weather.temp_f}°
            </span>
            <span class="font-mono text-xs text-base-content/80">{@weather.label}</span>
            <div class="font-mono text-[0.625rem] tabular-nums text-base-content/70">
              <div>{@weather.high_f}° / {@weather.low_f}° · feels {@weather.feels_like_f}°</div>
              <div>{@weather.wind_mph} mph · {@weather.humidity}%</div>
            </div>
            <button
              type="button"
              phx-click="edit_weather_location"
              aria-label="Change location"
              class="font-mono text-[0.625rem] uppercase tracking-wide text-base-content/45 transition hover:text-primary"
            >
              Change
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
