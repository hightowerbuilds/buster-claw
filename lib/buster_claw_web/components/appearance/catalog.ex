defmodule BusterClawWeb.Appearance.Catalog do
  @moduledoc """
  The Backgrounds pickers on Settings → Appearance: two buttons under the
  Background preview — **Images** and **Shaders** — each opening a modal with
  its half of the catalog, where a row IS the control: click it and it
  becomes the background. The Clock picks from the same catalog through
  `clock_picker/1`, a select inside the Clock panel.

  Three shapes in one day (10-17). First every row carried a button per
  surface (the terminal had a background of its own). Then the catalog was a
  column of its own, images over shaders, and the page was laid out for one
  screen. Then the column became two buttons and two modals, so the first
  column could hold the current background and the clock instead — what the
  operator looks at most, with the choosing one click away.

  Every event raised here — `open_picker`, `close_picker`, `assign_background`,
  `remove_image`, `validate_upload`, `save_upload`, `cancel_upload` — lands in
  `AppearanceLive`; a function component's `phx-click` reaches the LiveView it
  renders inside, so this is markup plus the pure helpers it reads.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Appearance

  @doc """
  The two buttons under the Background preview: **Images** and **Shaders**.
  Each opens `catalog_modal/1` for its half of the catalog (`open_picker`),
  which is the whole Backgrounds UI the page shows until one is pressed
  (one screen, 10-17 — the catalog used to be a column of its own).
  """
  attr :background, :map, required: true

  def background_pickers(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2 border-t-2 border-base-content/15 p-3">
      <button
        type="button"
        id="open-images"
        phx-click="open_picker"
        phx-value-kind="images"
        aria-haspopup="dialog"
        class={picker_btn(@background.kind in [:image, :image_shader])}
      >
        <.icon name="hero-photo" class="size-4" /> Images
      </button>
      <button
        type="button"
        id="open-shaders"
        phx-click="open_picker"
        phx-value-kind="shaders"
        aria-haspopup="dialog"
        class={picker_btn(@background.kind in [:none, :shader])}
      >
        <.icon name="hero-sparkles" class="size-4" /> Shaders
      </button>
    </div>
    """
  end

  # The button whose half of the catalog is in use is outlined, so the pair
  # also says which kind of background this is.
  defp picker_btn(current?) do
    [
      "inline-flex items-center justify-center gap-2 rounded border-2 px-3 py-2 text-xs font-semibold transition hover:border-primary hover:text-primary",
      if(current?, do: "border-primary", else: "border-base-content/30")
    ]
  end

  @doc """
  The catalog, one half at a time, as a modal: `kind` is `:images` (the pool,
  with its upload) or `:shaders` (`off` and every shader). A row IS the
  button; picking one raises `assign_background` for the background, and the
  LiveView closes the modal on success. Escape, the backdrop and the × raise
  `close_picker`.

  `background` is the resolved app background, so the row in use can say so;
  `upload` is the `:background` upload config from the LiveView.
  """
  attr :kind, :atom, required: true, values: [:images, :shaders]
  attr :image_options, :list, required: true
  attr :shader_options, :list, required: true
  attr :background, :map, required: true
  attr :upload, :any, required: true
  attr :pool_full, :boolean, required: true

  def catalog_modal(assigns) do
    ~H"""
    <div
      id="catalog-modal"
      data-picker={@kind}
      class="fixed inset-0 z-50"
      role="dialog"
      aria-modal="true"
      aria-labelledby="catalog-modal-title"
      phx-window-keydown="close_picker"
      phx-key="escape"
    >
      <%!-- The backdrop is a button so a click outside closes, and a
            screen reader is told what it does. --%>
      <button
        type="button"
        phx-click="close_picker"
        aria-label="Close"
        class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
      >
      </button>
      <div class="pointer-events-none absolute inset-0 grid place-items-center p-6">
        <section class="ic-panel pointer-events-auto flex max-h-full w-full max-w-3xl flex-col overflow-hidden">
          <div class="ic-panel-h shrink-0">
            <span id="catalog-modal-title">
              {if @kind == :images, do: "Images", else: "Shaders"}
            </span>
            <span class="flex items-center gap-3">
              <span class="font-sans text-xs normal-case tracking-normal text-base-content/55">
                Click one to use it as the background
              </span>
              <button
                type="button"
                phx-click="close_picker"
                aria-label="Close"
                class="grid size-7 place-items-center rounded-sm border-2 border-base-content/30 text-base leading-none transition hover:border-primary hover:text-primary"
              >
                ×
              </button>
            </span>
          </div>

          <div class="min-h-0 flex-1 overflow-y-auto p-5">
            <.images_half
              :if={@kind == :images}
              image_options={@image_options}
              background={@background}
              upload={@upload}
              pool_full={@pool_full}
            />
            <.shaders_half
              :if={@kind == :shaders}
              shader_options={@shader_options}
              background={@background}
            />
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :image_options, :list, required: true
  attr :background, :map, required: true
  attr :upload, :any, required: true
  attr :pool_full, :boolean, required: true

  defp images_half(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-baseline justify-between gap-2">
        <p class="ic-eyebrow">Your images</p>
        <span class="font-mono text-[0.625rem] text-base-content/45">
          {length(Enum.filter(@image_options, & &1.filled))} of {Appearance.max_images()}
        </span>
      </div>

      <%!-- Filled slots only. An empty slot is not a background and earned
            no tile; the one "Add" tile stands for all of them. --%>
      <div class="grid grid-cols-3 gap-3 sm:grid-cols-4">
        <.image_tile
          :for={opt <- @image_options}
          :if={opt.filled}
          opt={opt}
          in_use={in_use?(@background, opt)}
        />
        <.upload_tile :if={!@pool_full} upload={@upload} />
      </div>

      <%!-- The upload form owns the drop tile above by `for`/`id` rather
            than by nesting, so the tile can sit in the grid while the
            pending entry and the submit button sit below it. --%>
      <form
        id="background-upload-form"
        phx-change="validate_upload"
        phx-submit="save_upload"
        class="space-y-2"
      >
        <.live_file_input upload={@upload} class="sr-only" />

        <div
          :for={entry <- @upload.entries}
          class="flex items-center gap-2 rounded border-2 border-base-content/15 p-2"
        >
          <.live_img_preview entry={entry} class="h-10 w-16 shrink-0 rounded object-cover" />
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

      <p class="text-[0.6875rem] leading-4 text-base-content/50">
        PNG, JPG, WEBP or GIF, up to 8 MB. Adding one never changes the background
        until you click it. An image on the background can take a shader overlay
        from the Background panel.
      </p>
    </div>
    """
  end

  attr :shader_options, :list, required: true
  attr :background, :map, required: true

  defp shaders_half(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-baseline justify-between gap-2">
        <p class="ic-eyebrow">Shaders</p>
        <span class="font-mono text-[0.625rem] text-base-content/45">
          WebGPU · <span class="normal-case">shaders/*.wgsl</span> appear here
        </span>
      </div>

      <div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
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
      <.icon name="hero-plus" class="size-5" />
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

  # One filled image-pool slot: the thumbnail is the button, the name sits
  # under it, and the remove control appears on hover. The thumbnail is the
  # only way to tell one image from another, so it is most of the tile.
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
        class="block w-full text-left"
      >
        <span class="relative block aspect-video w-full bg-base-200">
          <span
            class="absolute inset-0 bg-cover bg-center"
            style={"background-image:url('#{@opt.url}')"}
          >
          </span>
          <.in_use_badge :if={@in_use} class="absolute left-1 top-1" />
        </span>
        <span class="block truncate border-t border-base-content/15 px-2 py-1 text-xs font-semibold">
          {@opt.label}
        </span>
      </button>
      <button
        type="button"
        phx-click="remove_image"
        phx-value-slot={@opt.slot}
        title="Remove this image"
        aria-label={"Remove #{@opt.label}"}
        class="absolute right-1 top-1 grid size-6 place-items-center rounded bg-base-100/80 text-base-content/70 opacity-0 transition group-hover:opacity-100 hover:text-error focus:opacity-100"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
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
