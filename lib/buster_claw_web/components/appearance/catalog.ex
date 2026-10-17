defmodule BusterClawWeb.Appearance.Catalog do
  @moduledoc """
  The Backgrounds catalog on Settings → Appearance: the image pool with its
  upload form, then every shader. Each row IS the control — click it and it
  becomes the background.

  Redesigned 10-17. Until then every row carried one button per surface (Home,
  Term, Clock), because the terminal had a background of its own. It does not
  any more — a terminal is transparent over the app background — so the catalog
  has one job: pick the background. The clock, which is a widget with its own
  sky, picks from the same catalog through `clock_picker/1`, which sits inside
  the Clock panel rather than on every row.

  Extracted from `AppearanceLive.render/1` on 10-16 (CODE_QUALITY_SWEEP Phase 7)
  by the purity rule: this is markup plus the pure helpers that only the markup
  reads. Every event it raises — `assign_background`, `remove_image`,
  `validate_upload`, `save_upload`, `cancel_upload` — still lands in
  `AppearanceLive`; a function component's `phx-click` reaches the LiveView it
  renders inside, so moving the markup moved no state.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Appearance

  @doc """
  The catalog cell: a panel that fills the grid row beside the surface panels.

  `background` is the resolved app background, so the row in use can say so;
  `upload` is the `:background` upload config from the LiveView.
  """
  attr :image_options, :list, required: true
  attr :shader_options, :list, required: true
  attr :background, :map, required: true
  attr :upload, :any, required: true
  attr :pool_full, :boolean, required: true

  def backgrounds_catalog(assigns) do
    ~H"""
    <%!-- The catalog is exactly as tall as the two panels beside it. This
          wrapper is the grid cell, which the default `align-items: stretch`
          sizes to the row; from `lg` up the panel is taken out of flow to
          fill it. Out of flow is the whole trick — in flow, a long option
          list would drive the row height instead of the other way round.
          Below `lg` the columns stack and the panel sizes to its content. --%>
    <div class="relative min-h-[22rem]">
      <section class="ic-panel flex flex-col overflow-hidden lg:absolute lg:inset-0">
        <div class="ic-panel-h shrink-0">
          <span>Backgrounds</span>
          <span class="font-sans text-xs normal-case tracking-normal text-base-content/55">
            Click one to use it
          </span>
        </div>

        <%!-- The scroll container. min-h-0 is what actually lets a flex child
            shrink below its content and scroll instead of growing. --%>
        <div class="min-h-0 flex-1 space-y-4 overflow-y-auto p-5">
          <p class="text-sm leading-7 text-base-content/70">
            One background for the whole Work Area — the chat, the panels and
            every terminal sit on it. The clock has its own, on the right.
          </p>

          <p class="ic-eyebrow">Your images</p>

          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <.image_tile :for={opt <- @image_options} opt={opt} in_use={in_use?(@background, opt)} />
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
            background just stays solid. Drop a <span class="font-mono text-xs">.wgsl</span>
            file into your workspace's <span class="font-mono text-xs">shaders/</span>
            folder and it appears here without a rebuild.
          </p>

          <%!-- Said out loud, because applying a shader quietly grants a
                standing capability the operator did not come here to grant
                (AGENT_APPLIED_SHADERS_ROADMAP, risk VII.2). A line rather
                than a confirmation: a background is visible the instant it
                happens and undone by one more click, so gating it would only
                teach the operator to click through the gates that do matter.
                The second sentence is not decoration — approval is keyed to
                the file's contents, so an edited shader really does go back
                to needing a click, and an operator who wasn't told that would
                read it as the feature failing. --%>
          <p class="text-xs leading-5 text-base-content/55">
            Applying one of your own shaders also lets commands re-apply
            that exact file later. Edit the file and they'll need you to pick it again.
          </p>

          <%!-- One shader per row: the names are the whole content, so a
              single column reads as a list instead of a ragged wrap. --%>
          <div class="flex flex-col gap-2">
            <.option_chip :for={opt <- @shader_options} opt={opt} in_use={in_use?(@background, opt)} />
          </div>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  The Clock's picker: one `<select>` over the same catalog, plus the shipped
  sky, which has no catalog row because nothing may select it by name
  (`Appearance.default_mode/0` is the way back to it).

  A select rather than a second grid: the clock is the secondary surface, and a
  second copy of the whole catalog on the same page is what the 10-17 redesign
  removed. Changing it fires the same `assign_background` event a catalog row
  does, with `surface=widget`.
  """
  attr :bg, :map, required: true
  attr :options, :list, required: true, doc: "every filled catalog option"

  def clock_picker(assigns) do
    ~H"""
    <form
      id="clock-picker"
      phx-change="assign_background"
      class="flex flex-wrap items-center gap-3 border-t-2 border-base-content/15 p-4"
    >
      <input type="hidden" name="surface" value="widget" />
      <label for="clock-background" class="text-sm font-semibold">Sky</label>
      <select
        id="clock-background"
        name="option"
        class="min-w-0 flex-1 rounded border-2 border-base-content/25 bg-base-100 px-2 py-1 text-sm"
      >
        <option value={Appearance.default_mode()} selected={shipped?(@bg, @options)}>
          Day cycle (default)
        </option>
        <option :for={opt <- @options} value={opt.key} selected={in_use?(@bg, opt)}>
          {opt.label}
        </option>
      </select>
      <p class="w-full text-sm text-base-content/50">
        The clock is a widget with a sky of its own. Any background works here too.
      </p>
    </form>
    """
  end

  # A non-image option (off, or a shader). No thumbnail: the only honest preview
  # of a shader is the shader itself, and that runs live in the Background panel
  # beside it. The row is the whole control.
  #
  # `data-bg-option` names which option the row is. It backs the tests (and any
  # later automation); nothing in the UI reads it. The button carries
  # `phx-value-surface` so the one event has one shape wherever it comes from.
  attr :opt, :map, required: true
  attr :in_use, :boolean, required: true

  defp option_chip(assigns) do
    ~H"""
    <div data-bg-option={@opt.key}>
      <button
        type="button"
        phx-click="assign_background"
        phx-value-surface="home"
        phx-value-option={@opt.key}
        aria-pressed={to_string(@in_use)}
        aria-label={"Use #{@opt.label} as the background"}
        class={[
          "flex w-full items-center gap-2 rounded border-2 py-2 pl-3 pr-2 text-left transition",
          if(@in_use, do: "border-primary", else: "border-base-content/25 hover:border-primary")
        ]}
      >
        <.icon
          name={if(@opt.kind == :off, do: "hero-no-symbol", else: "hero-sparkles")}
          class="size-4 shrink-0 text-base-content/45"
        />
        <%!-- The label is the item that yields: flex items do not shrink
              below their content by default, so a long shader name would push
              the badge out of the row instead of ellipsing. --%>
        <span class="min-w-0 flex-1 truncate text-sm font-semibold">{@opt.label}</span>
        <.in_use_badge :if={@in_use} />
      </button>
    </div>
    """
  end

  # One image-pool slot. An image DOES get a thumbnail — it is the only way to
  # tell one from another. The thumbnail is the button; the remove control sits
  # in the footer, outside it, because a button may not contain a button.
  attr :opt, :map, required: true
  attr :in_use, :boolean, required: true

  defp image_tile(assigns) do
    ~H"""
    <div
      data-bg-option={@opt.key}
      class={[
        "flex flex-col overflow-hidden rounded-lg border-2 transition",
        if(@in_use, do: "border-primary", else: "border-base-content/20"),
        @opt.filled && !@in_use && "hover:border-primary"
      ]}
    >
      <button
        :if={@opt.filled}
        type="button"
        phx-click="assign_background"
        phx-value-surface="home"
        phx-value-option={@opt.key}
        aria-pressed={to_string(@in_use)}
        aria-label={"Use #{@opt.label} as the background"}
        class="relative aspect-video w-full bg-base-200"
      >
        <span
          class="absolute inset-0 bg-cover bg-center"
          style={"background-image:url('#{@opt.url}')"}
        >
        </span>
        <.in_use_badge :if={@in_use} class="absolute left-1.5 top-1.5" />
      </button>
      <div :if={!@opt.filled} class="grid aspect-video w-full place-items-center bg-base-200">
        <span class="text-xs text-base-content/40">Empty</span>
      </div>

      <div class="flex items-center justify-between gap-1 border-t border-base-content/15 bg-base-100 px-2 py-1.5">
        <span class="truncate text-xs font-semibold">{@opt.label}</span>
        <button
          :if={@opt.filled}
          type="button"
          phx-click="remove_image"
          phx-value-slot={@opt.slot}
          title="Remove this image"
          aria-label={"Remove #{@opt.label}"}
          class="grid size-6 shrink-0 place-items-center rounded text-base-content/45 transition hover:text-error"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  attr :class, :string, default: nil

  defp in_use_badge(assigns) do
    ~H"""
    <span
      data-assigned="background"
      class={[
        "shrink-0 rounded bg-primary px-1.5 py-0.5 text-[0.625rem] font-bold uppercase tracking-wide text-primary-content",
        @class
      ]}
    >
      In use
    </span>
    """
  end

  # Whether `background` is running `opt`.
  #
  # `catalog_key/1`, not `option_key/1`: an image carrying a shader overlay
  # stores as `image:5+veil` and would match no tile, so the grid went blank
  # while the surface panel still said "Image 5 + veil".
  defp in_use?(background, opt), do: Appearance.catalog_key(background) == opt.key

  # The clock is on its shipped sky exactly when no catalog row is in use: the
  # sky is a `@default_only_shaders` name with no row, so this is the one
  # question the catalog cannot answer by matching.
  defp shipped?(bg, options), do: not Enum.any?(options, &in_use?(bg, &1))

  defp upload_error_to_string(:too_large), do: "That image is larger than 8 MB."
  defp upload_error_to_string(:too_many_files), do: "Choose a single image."
  defp upload_error_to_string(:not_accepted), do: "Use a PNG, JPG, WEBP, or GIF image."
  defp upload_error_to_string(_), do: "That image couldn't be uploaded."
end
