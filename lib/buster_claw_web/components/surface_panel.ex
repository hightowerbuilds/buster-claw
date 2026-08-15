defmodule BusterClawWeb.SurfacePanel do
  @moduledoc """
  One surface's panel in Settings → Appearance: what that surface is running
  right now, live, plus the controls that only make sense for what it is running
  — the custom palette for a shader, and the overlay picker for an image.

  Extracted from `AppearanceLive` by `IMAGE_SHADER_ROADMAP` Phase 3, which is the
  cut that file's size-cap comment had already named. The events it raises
  (`toggle_custom`, `set_colors`, `set_overlay`) are still handled by
  `AppearanceLive` — a function component's `phx-click` reaches the LiveView it
  renders inside, so moving the markup moved no state.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Appearance

  @doc """
  Render `bg`'s panel for `surface`.

  `overlays` is the list of shader names that may be laid over an image
  (`Appearance.image_shader_options/0`) — passed in rather than computed here so
  the component stays a pure render.
  """
  attr :surface, :atom, required: true
  attr :bg, :map, required: true
  attr :overlays, :list, default: []

  def surface_target(assigns) do
    ~H"""
    <section
      id={"surface-#{@surface}"}
      aria-label={"#{Appearance.surface_label(@surface)} background"}
      class="ic-panel flex flex-col overflow-hidden"
    >
      <div class="ic-panel-h">
        <span>{Appearance.surface_label(@surface)}</span>
        <span class="font-sans text-xs normal-case tracking-normal text-base-content/55">
          {current_label(@bg)}
        </span>
      </div>

      <%!-- aspect-video keeps the shape honest on a narrow window; the max-height
            caps how much vertical room a target eats on a wide one. --%>
      <div class="relative aspect-video max-h-40 w-full overflow-hidden bg-base-200">
        <%= cond do %>
          <% shader_backed?(@bg) -> %>
            <%!-- The preview runs the SAME shader the surface runs, and for an
                  image overlay it is handed the SAME image — otherwise the one
                  screen you visit in order to see the effect is the one screen
                  that does not show it. Keyed by image url too, so swapping the
                  picture underneath remounts the preview. --%>
            <div
              id={"#{@surface}-surface-preview-#{@bg.shader}-#{@bg.custom}-#{:erlang.phash2(@bg[:image_url])}"}
              phx-hook="ShaderPreview"
              phx-update="ignore"
              data-shader={@bg.shader}
              data-shader-source={@bg.source_url}
              data-custom={to_string(@bg.custom)}
              data-image-url={@bg[:image_url]}
              data-color-prefix={"#{@surface}-color-"}
              class="absolute inset-0"
              aria-label={"#{@bg.shader} shader preview"}
            >
              <canvas class="block h-full w-full"></canvas>
            </div>
          <% @bg.kind == :image -> %>
            <div
              class="absolute inset-0 bg-cover bg-center"
              style={"background-image:url('#{@bg.image_url}')"}
            >
            </div>
          <% true -> %>
            <div class="grid h-full place-items-center text-sm text-base-content/40">
              <span class="flex items-center gap-2">
                <.icon name="hero-no-symbol" class="size-4" /> No background
              </span>
            </div>
        <% end %>
      </div>

      <%!-- The overlay picker. Only an image can carry one, so this appears
            exactly when the surface is showing one — with or without an overlay
            already on it. --%>
      <div
        :if={@bg.kind in [:image, :image_shader] and @overlays != []}
        class="space-y-2 border-t-2 border-base-content/15 p-4"
      >
        <form phx-change="set_overlay" class="flex flex-wrap items-center gap-3">
          <input type="hidden" name="surface" value={@surface} />
          <label
            for={"#{@surface}-overlay"}
            class="text-sm font-semibold"
          >
            Shader overlay
          </label>
          <select
            id={"#{@surface}-overlay"}
            name="shader"
            class="rounded border-2 border-base-content/25 bg-base-100 px-2 py-1 text-sm"
          >
            <option value="" selected={@bg.kind == :image}>None</option>
            <option
              :for={name <- @overlays}
              value={name}
              selected={@bg.kind == :image_shader and @bg.shader == name}
            >
              {Appearance.shader_label(name)}
            </option>
          </select>
        </form>
        <p class="text-sm text-base-content/50">
          A pattern drawn <em>from</em> the picture — it reads the image and thins where
          the image is bright.
        </p>
      </div>

      <div :if={shader_backed?(@bg)} class="space-y-3 border-t-2 border-base-content/15 p-4">
        <label class="inline-flex cursor-pointer items-center gap-2 text-sm font-semibold">
          <input
            type="checkbox"
            checked={@bg.custom}
            phx-click="toggle_custom"
            phx-value-surface={@surface}
            class="size-4 accent-primary"
          /> Use custom colors
        </label>

        <form :if={@bg.custom} phx-change="set_colors" class="flex flex-wrap gap-4">
          <input type="hidden" name="surface" value={@surface} />
          <label :for={{hex, i} <- Enum.with_index(@bg.colors)} class="flex items-center gap-2">
            <input
              type="color"
              id={"#{@surface}-color-#{i + 1}"}
              name={"c#{i + 1}"}
              value={hex}
              phx-debounce="250"
              class="size-9 cursor-pointer rounded border-2 border-base-content/20 bg-transparent p-0.5"
            />
            <span class="text-xs text-base-content/60">
              {Enum.at(~w(Base Accent Highlight), i)}
            </span>
          </label>
        </form>

        <p :if={!@bg.custom} class="text-sm text-base-content/50">
          Using the design's built-in colors.
        </p>
      </div>
    </section>
    """
  end

  defp shader_backed?(bg), do: BusterClawWeb.ShaderCanvas.shader_backed?(bg)

  defp current_label(%{kind: :none}), do: "Off"
  defp current_label(%{kind: :image, slot: slot}), do: "Image #{slot}"
  defp current_label(%{kind: :image_shader, slot: slot, shader: s}), do: "Image #{slot} + #{s}"
  defp current_label(%{kind: :shader, shader: shader}), do: shader
end
