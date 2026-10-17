defmodule BusterClawWeb.Appearance.Catalog do
  @moduledoc """
  The Backgrounds catalog on Settings → Appearance: the image pool with its
  upload form, then every shader, each row carrying a Home and a Term button.

  Extracted from `AppearanceLive.render/1` on 10-16 (CODE_QUALITY_SWEEP Phase 7)
  by the purity rule: this is markup plus the pure helpers that only the markup
  reads (`assigned_to/2`, `short_label/1`, the upload error text). Every event
  it raises — `assign_background`, `remove_image`, `validate_upload`,
  `save_upload`, `cancel_upload` — still lands in `AppearanceLive`; a function
  component's `phx-click` reaches the LiveView it renders inside, so moving the
  markup moved no state.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Appearance

  @doc """
  The catalog cell: a panel that fills the grid row beside the surface panels.

  `backgrounds` is `%{surface => bg}` so each row can badge the surfaces it is
  running on; `upload` is the `:background` upload config from the LiveView.
  """
  attr :image_options, :list, required: true
  attr :shader_options, :list, required: true
  attr :backgrounds, :map, required: true
  attr :upload, :any, required: true
  attr :pool_full, :boolean, required: true

  def backgrounds_catalog(assigns) do
    ~H"""
    <%!-- The catalog is exactly as tall as the two surface panels beside
          it. This wrapper is the grid cell, which the default
          `align-items: stretch` sizes to the row; from `lg` up the panel
          is taken out of flow to fill it. Out of flow is the whole trick —
          in flow, a long option list would drive the row height instead of
          the other way round. Below `lg` the columns stack and the panel
          sizes to its content as usual. --%>
    <div class="relative min-h-[22rem]">
      <section class="ic-panel flex flex-col overflow-hidden lg:absolute lg:inset-0">
        <div class="ic-panel-h shrink-0">
          <span>Backgrounds</span>
          <span class="font-sans text-xs normal-case tracking-normal text-base-content/55">
            Send to a surface →
          </span>
        </div>

        <%!-- The scroll container. min-h-0 is what actually lets a flex child
            shrink below its content and scroll instead of growing. --%>
        <div class="min-h-0 flex-1 space-y-4 overflow-y-auto p-5">
          <p class="text-sm leading-7 text-base-content/70">
            One set of options for both surfaces; pick the same one twice if you
            like. Each row's <span class="font-semibold">Home</span>
            and <span class="font-semibold">Term</span>
            buttons send it to that surface.
          </p>

          <p class="ic-eyebrow">Your images</p>

          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <.image_tile
              :for={opt <- @image_options}
              opt={opt}
              assigned={assigned_to(@backgrounds, opt)}
            />
          </div>

          <form
            id="background-upload-form"
            phx-change="validate_upload"
            phx-submit="save_upload"
            class="space-y-3 pt-2"
          >
            <label
              phx-drop-target={@upload.ref}
              class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-base-content/25 px-4 py-6 text-center transition hover:border-primary"
            >
              <.icon name="hero-photo" class="size-7 text-base-content/50" />
              <span class="text-sm font-semibold">Drop an image here, or click to choose</span>
              <span class="font-mono text-xs text-base-content/50">
                PNG, JPG, WEBP, GIF · up to 8 MB
              </span>
              <.live_file_input upload={@upload} class="sr-only" />
            </label>

            <div
              :for={entry <- @upload.entries}
              class="flex items-center gap-3 rounded-lg border-2 border-base-content/15 p-2.5"
            >
              <.live_img_preview entry={entry} class="h-12 w-20 shrink-0 rounded object-cover" />
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-semibold">{entry.client_name}</div>
                <div class="font-mono text-xs text-base-content/50">{entry.progress}%</div>
              </div>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                aria-label="Cancel upload"
                class="grid size-8 place-items-center rounded-sm text-base-content/60 transition hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p :for={err <- upload_errors(@upload)} class="text-sm text-error">
              {upload_error_to_string(err)}
            </p>

            <p :if={@pool_full} class="text-sm text-base-content/60">
              All {Appearance.max_images()} image slots are full — remove one to add another.
            </p>

            <button
              type="submit"
              disabled={@upload.entries == [] or @pool_full}
              class="inline-flex items-center gap-2 rounded border-2 border-primary px-4 py-2 text-sm font-semibold text-primary transition hover:bg-primary hover:text-primary-content disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Add to catalog
            </button>
          </form>

          <p class="ic-eyebrow pt-2">Shaders</p>

          <p class="text-sm leading-7 text-base-content/70">
            Shaders need WebGPU (the desktop app) — where it's unavailable the
            surface just stays solid. Drop a <span class="font-mono text-xs">.wgsl</span>
            file into your workspace's <span class="font-mono text-xs">shaders/</span>
            folder and it appears here without a rebuild.
          </p>

          <%!-- Said out loud, because sending a shader to a surface quietly
                grants a standing capability the operator did not come here
                to grant (AGENT_APPLIED_SHADERS_ROADMAP, risk VII.2). A line
                rather than a confirmation: a background is visible the
                instant it happens and undone by one more click, so gating it
                would only teach the operator to click through the gates that
                do matter. The second sentence is not decoration — approval
                is keyed to the file's contents, so an edited shader really
                does go back to needing a click, and an operator who wasn't
                told that would read it as the feature failing. --%>
          <p class="text-xs leading-5 text-base-content/55">
            Sending one of your own shaders to a surface also lets commands re-apply
            that exact file later. Edit the file and they'll need you to pick it again.
          </p>

          <%!-- One shader per row: the names are the whole content, so a
              single column reads as a list instead of a ragged wrap. --%>
          <div class="flex flex-col gap-2">
            <.option_chip
              :for={opt <- @shader_options}
              opt={opt}
              assigned={assigned_to(@backgrounds, opt)}
            />
          </div>
        </div>
      </section>
    </div>
    """
  end

  # A non-image option (off, or a shader). No thumbnail: the only honest preview
  # of a shader is the shader itself, and that runs live in the surface panels
  # beside it. The row is the whole control — name, in-use marks, and the two
  # buttons that send it to a surface.
  #
  # `data-bg-option` names which option the row is. It backs the tests (and any
  # later automation); nothing in the UI reads it.
  attr :opt, :map, required: true
  attr :assigned, :list, required: true

  defp option_chip(assigns) do
    ~H"""
    <div
      data-bg-option={@opt.key}
      class={[
        "flex w-full items-center gap-2 rounded border-2 py-1.5 pl-3 pr-1.5 transition",
        if(@assigned == [],
          do: "border-base-content/25 hover:border-primary",
          else: "border-primary"
        )
      ]}
    >
      <.icon
        name={if(@opt.kind == :off, do: "hero-no-symbol", else: "hero-sparkles")}
        class="size-4 shrink-0 text-base-content/45"
      />
      <%!-- The label is the item that yields. Flex items do not shrink below
            their content by default, so before this a long shader name pushed
            the buttons out of the row instead of ellipsing — invisible with two
            surfaces, and the third is what made it reachable. --%>
      <span class="min-w-0 flex-1 truncate text-sm font-semibold">{@opt.label}</span>

      <span
        :if={@assigned != []}
        data-assigned={assigned_badge(@assigned)}
        class="shrink-0 rounded bg-primary px-1.5 py-0.5 text-[0.625rem] font-bold uppercase tracking-wide text-primary-content"
      >
        {assigned_badge(@assigned)}
      </span>

      <span class="flex shrink-0 items-center gap-0.5 border-l-2 border-base-content/15 pl-1.5">
        <.assign_button :for={surface <- Appearance.surfaces()} surface={surface} opt={@opt} />
      </span>
    </div>
    """
  end

  # One image-pool slot. An image DOES get a thumbnail — it is the only way to
  # tell one from another.
  attr :opt, :map, required: true
  attr :assigned, :list, required: true

  defp image_tile(assigns) do
    ~H"""
    <div
      data-bg-option={@opt.key}
      class={[
        "flex flex-col overflow-hidden rounded-lg border-2 transition",
        if(@assigned == [],
          do: "border-base-content/20 hover:border-primary",
          else: "border-primary"
        )
      ]}
    >
      <div class="relative aspect-video w-full bg-base-200">
        <div
          :if={@opt.filled}
          class="absolute inset-0 bg-cover bg-center"
          style={"background-image:url('#{@opt.url}')"}
        >
        </div>
        <div
          :if={!@opt.filled}
          class="grid h-full place-items-center text-xs text-base-content/40"
        >
          Empty
        </div>

        <span
          :if={@assigned != []}
          data-assigned={assigned_badge(@assigned)}
          class="absolute left-1.5 top-1.5 rounded bg-primary px-1.5 py-0.5 text-[0.625rem] font-bold uppercase tracking-wide text-primary-content"
        >
          {assigned_badge(@assigned)}
        </span>
      </div>

      <div class="flex items-center justify-between gap-1 border-t border-base-content/15 bg-base-100 px-2 py-1.5">
        <span class="truncate text-xs font-semibold">{@opt.label}</span>

        <span :if={@opt.filled} class="flex shrink-0 items-center gap-0.5">
          <.assign_button :for={surface <- Appearance.surfaces()} surface={surface} opt={@opt} />
          <button
            type="button"
            phx-click="remove_image"
            phx-value-slot={@opt.slot}
            title="Remove this image"
            aria-label={"Remove #{@opt.label}"}
            class="grid size-6 place-items-center rounded text-base-content/45 transition hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </span>
      </div>
    </div>
    """
  end

  # Send this option to a surface. Shared by both row shapes so the two can't
  # drift apart.
  attr :surface, :atom, required: true
  attr :opt, :map, required: true

  defp assign_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="assign_background"
      phx-value-surface={@surface}
      phx-value-option={@opt.key}
      title={"Use for #{Appearance.surface_label(@surface)}"}
      aria-label={"Use #{@opt.label} for #{Appearance.surface_label(@surface)}"}
      class="rounded px-1.5 py-1 text-[0.625rem] font-bold uppercase tracking-wide text-base-content/55 transition hover:bg-base-200 hover:text-primary"
    >
      {short_label(@surface)}
    </button>
    """
  end

  # Which surfaces currently run this option, so the tile can badge itself.
  #
  # `catalog_key/1`, not `option_key/1`: an image carrying a shader overlay
  # stores as `image:5+veil` and would match no tile, so the grid went blank
  # while the surface panel still said "Image 5 + veil".
  defp assigned_to(backgrounds, opt) do
    Enum.filter(Appearance.surfaces(), fn surface ->
      Appearance.catalog_key(backgrounds[surface]) == opt.key
    end)
  end

  defp assigned_badge(surfaces), do: Enum.map_join(surfaces, " · ", &short_label/1)

  # One clause per surface, and a missing one is a crash rather than a fallback
  # — deliberately. `Appearance.surfaces/0` is what the buttons iterate, so a
  # surface added there with no label here would otherwise render a blank button
  # nobody notices. The widget arrived on 08-15 and this is where it landed
  # (WIDGET_BACKGROUND I.5, which predicted it).
  defp short_label(:home), do: "Home"
  defp short_label(:terminal), do: "Term"
  defp short_label(:widget), do: "Clock"

  defp upload_error_to_string(:too_large), do: "That image is larger than 8 MB."
  defp upload_error_to_string(:too_many_files), do: "Choose a single image."
  defp upload_error_to_string(:not_accepted), do: "Use a PNG, JPG, WEBP, or GIF image."
  defp upload_error_to_string(_), do: "That image couldn't be uploaded."
end
