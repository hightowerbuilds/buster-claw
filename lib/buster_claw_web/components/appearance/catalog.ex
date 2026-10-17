defmodule BusterClawWeb.Appearance.Catalog do
  @moduledoc """
  The Backgrounds catalog on Settings → Appearance: the image pool with its
  upload form, then every shader. Each row IS the control — click it and it
  becomes the background.

  Laid out for one screen the same day: filled images as small tiles with one
  "Add" tile, shaders two per row, and the panel scrolls inside itself.

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
    <%!-- The grid cell is bounded by the viewport (`Layouts.app fit_viewport`),
          so this panel is a flex column that scrolls inside itself; the page
          never scrolls. Images first, then the shaders — the two shapes the
          catalog comes in, in the order the operator reaches for them. --%>
    <section class="ic-panel flex min-h-0 flex-col overflow-hidden">
      <div class="ic-panel-h shrink-0">
        <span>Backgrounds</span>
        <span class="font-sans text-xs normal-case tracking-normal text-base-content/55">
          Click one to use it
        </span>
      </div>

      <div class="min-h-0 flex-1 space-y-3 overflow-y-auto p-4">
        <div class="flex items-baseline justify-between gap-2">
          <p class="ic-eyebrow">Your images</p>
          <span class="font-mono text-[0.625rem] text-base-content/45">
            {length(Enum.filter(@image_options, & &1.filled))} of {Appearance.max_images()}
          </span>
        </div>

        <%!-- Filled slots only, small. An empty slot is not a background and
              earned no tile; the one "Add" tile stands for all of them. --%>
        <div class="grid grid-cols-4 gap-2">
          <.image_tile
            :for={opt <- @image_options}
            :if={opt.filled}
            opt={opt}
            in_use={in_use?(@background, opt)}
          />
          <.upload_tile :if={!@pool_full} upload={@upload} />
        </div>

        <%!-- The upload form wraps the drop tile above by `form` attribute
              rather than by nesting, so the tile can sit inside the image
              grid while the pending entry and the submit button sit below
              it. `phx-change` on the form still sees the input. --%>
        <form
          id="background-upload-form"
          phx-change="validate_upload"
          phx-submit="save_upload"
          class="space-y-2"
        >
          <.live_file_input upload={@upload} class="sr-only" />

          <div
            :for={entry <- @upload.entries}
            class="flex items-center gap-2 rounded border-2 border-base-content/15 p-1.5"
          >
            <.live_img_preview entry={entry} class="h-8 w-14 shrink-0 rounded object-cover" />
            <div class="min-w-0 flex-1">
              <div class="truncate text-xs font-semibold">{entry.client_name}</div>
              <div class="font-mono text-[0.625rem] text-base-content/50">{entry.progress}%</div>
            </div>
            <button
              type="submit"
              class="shrink-0 rounded border-2 border-primary px-2 py-1 text-[0.625rem] font-bold uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
            >
              Add to catalog
            </button>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              aria-label="Cancel upload"
              class="grid size-7 shrink-0 place-items-center rounded-sm text-base-content/60 transition hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <p :for={err <- upload_errors(@upload)} class="text-xs text-error">
            {upload_error_to_string(err)}
          </p>

          <p :if={@pool_full} class="text-xs text-base-content/60">
            All {Appearance.max_images()} slots are full — remove one to add another.
          </p>
        </form>

        <div class="flex items-baseline justify-between gap-2 pt-1">
          <p class="ic-eyebrow">Shaders</p>
          <span class="font-mono text-[0.625rem] text-base-content/45">
            WebGPU · <span class="normal-case">shaders/*.wgsl</span> appear here
          </span>
        </div>

        <%!-- Two per row: the names are short, and one column was most of
              what made the page scroll. --%>
        <div class="grid grid-cols-2 gap-1.5">
          <.option_chip :for={opt <- @shader_options} opt={opt} in_use={in_use?(@background, opt)} />
        </div>

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
        <p class="text-[0.6875rem] leading-4 text-base-content/50">
          Applying one of your own shaders also lets commands re-apply that exact
          file later. Edit the file and they'll need you to pick it again. Where
          WebGPU is unavailable the background stays solid.
        </p>
      </div>
    </section>
    """
  end

  # The drop target, tile-sized, living in the image grid. It is the upload
  # form's label (by `for`), so a click opens the chooser and a drop lands in
  # the same input.
  attr :upload, :any, required: true

  defp upload_tile(assigns) do
    ~H"""
    <label
      for={@upload.ref}
      phx-drop-target={@upload.ref}
      title="Add an image — PNG, JPG, WEBP or GIF, up to 8 MB"
      class="flex aspect-video cursor-pointer flex-col items-center justify-center gap-0.5 rounded border-2 border-dashed border-base-content/25 text-base-content/50 transition hover:border-primary hover:text-primary"
    >
      <.icon name="hero-plus" class="size-4" />
      <span class="text-[0.625rem] font-semibold uppercase tracking-wide">Add</span>
    </label>
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
      class="flex flex-wrap items-center gap-2 border-t-2 border-base-content/15 p-3"
    >
      <input type="hidden" name="surface" value="widget" />
      <label for="clock-background" class="text-xs font-semibold">Sky</label>
      <select
        id="clock-background"
        name="option"
        class="min-w-0 flex-1 rounded border-2 border-base-content/25 bg-base-100 px-2 py-1 text-xs"
      >
        <option value={Appearance.default_mode()} selected={shipped?(@bg, @options)}>
          Day cycle (default)
        </option>
        <option :for={opt <- @options} value={opt.key} selected={in_use?(@bg, opt)}>
          {opt.label}
        </option>
      </select>
      <p class="w-full truncate text-[0.6875rem] leading-4 text-base-content/50">
        The clock's own sky — any background works here too.
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
          "flex w-full items-center gap-1.5 rounded border-2 py-1 pl-2 pr-1.5 text-left transition",
          if(@in_use, do: "border-primary", else: "border-base-content/20 hover:border-primary")
        ]}
      >
        <.icon
          name={if(@opt.kind == :off, do: "hero-no-symbol", else: "hero-sparkles")}
          class="size-3.5 shrink-0 text-base-content/40"
        />
        <%!-- The label is the item that yields: flex items do not shrink
              below their content by default, so a long shader name would push
              the badge out of the row instead of ellipsing. --%>
        <span class="min-w-0 flex-1 truncate text-xs font-semibold">{@opt.label}</span>
        <.in_use_badge :if={@in_use} />
      </button>
    </div>
    """
  end

  # One filled image-pool slot, small: the thumbnail is the button, the name
  # is its tooltip, and the remove control appears on hover. The thumbnail is
  # the only way to tell one image from another, so it is the whole tile.
  attr :opt, :map, required: true
  attr :in_use, :boolean, required: true

  defp image_tile(assigns) do
    ~H"""
    <div
      data-bg-option={@opt.key}
      class={[
        "group relative overflow-hidden rounded border-2 transition",
        if(@in_use, do: "border-primary", else: "border-base-content/20 hover:border-primary")
      ]}
    >
      <button
        type="button"
        phx-click="assign_background"
        phx-value-surface="home"
        phx-value-option={@opt.key}
        aria-pressed={to_string(@in_use)}
        aria-label={"Use #{@opt.label} as the background"}
        title={@opt.label}
        class="relative block aspect-video w-full bg-base-200"
      >
        <span
          class="absolute inset-0 bg-cover bg-center"
          style={"background-image:url('#{@opt.url}')"}
        >
        </span>
        <.in_use_badge :if={@in_use} class="absolute left-1 top-1" />
      </button>
      <button
        type="button"
        phx-click="remove_image"
        phx-value-slot={@opt.slot}
        title="Remove this image"
        aria-label={"Remove #{@opt.label}"}
        class="absolute right-1 top-1 grid size-5 place-items-center rounded bg-base-100/80 text-base-content/70 opacity-0 transition group-hover:opacity-100 hover:text-error focus:opacity-100"
      >
        <.icon name="hero-x-mark" class="size-3" />
      </button>
    </div>
    """
  end

  attr :class, :string, default: nil

  defp in_use_badge(assigns) do
    ~H"""
    <span
      data-assigned="background"
      class={[
        "shrink-0 rounded bg-primary px-1 py-0.5 text-[0.5625rem] font-bold uppercase tracking-wide text-primary-content",
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
