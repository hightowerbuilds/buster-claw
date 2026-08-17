defmodule BusterClawWeb.SoundStudio.Overlays do
  @moduledoc """
  The Sound Studio's three floating surfaces: the sidebar's right-click menu,
  the assign-on-render prompt, and the file-info modal.

  Extracted from `SoundStudioComponent` (CODE_QUALITY_REFACTOR Phase 3B, 08-03),
  where `render/1` had grown to 826 lines — 43% of the module. These three came
  out first because they are the least entangled: between them they read only
  `@myself`, `@assign_render` and `@info`, so the extraction makes their real
  data dependency visible instead of hiding it in a shared assign soup.

  They are overlays, not layout: each is `fixed`, each is rendered once, and
  none of them participates in the arranger's sizing. That is why they can move
  without touching a single class on the surface underneath.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.SoundStudio.Format

  alias BusterClaw.Notifications.Sound

  attr :myself, :any, required: true, doc: "the component's phx-target"

  @doc """
  The sidebar's right-click menu. Rendered once and positioned by the hook.
  """
  def context_menu(assigns) do
    ~H"""
    <%!-- The sidebar's right-click menu. Rendered once, positioned and shown
          by the hook, and under `phx-update="ignore"` because the hook owns
          its text (the armed "Really delete?" state must survive a patch).
          `phx-target` + `pushEventTo(el)` routes delete_source to THIS
          component — Part V landmine 1; without the target it lands on
          StatusLive and crashes. Only sidebar items carrying data-deletable
          summon the menu — the server decides deletability, the hook only
          reads the marker. --%>
    <div
      id="studio-ctx"
      phx-hook="StudioContextMenu"
      phx-target={@myself}
      phx-update="ignore"
      hidden
      class="fixed z-50 min-w-40 border-2 border-base-content/30 bg-base-100 shadow-lg"
    >
      <%!-- Clip items. None of them touches a file — the source is untouched
            and ⌘Z puts any of them back — so none takes the two-step confirm
            that deleting a FILE does. --%>
      <button type="button" data-ctx-trim-clip hidden class={menu_item_class()}>
        Trim clip…
      </button>
      <button type="button" data-ctx-duplicate-clip hidden class={menu_item_class()}>
        Duplicate clip
      </button>
      <button type="button" data-ctx-remove-clip hidden class={menu_item_class()}>
        Remove clip
      </button>
      <button type="button" data-ctx-info hidden class={menu_item_class()}>
        Info
      </button>
      <button type="button" data-ctx-rename hidden class={menu_item_class()}>
        Rename
      </button>
      <button type="button" data-ctx-new-mix hidden class={menu_item_class()}>
        Add to new mix
      </button>
      <button type="button" data-ctx-delete hidden class={menu_item_class()}>
        Delete
      </button>
      <%!-- Rename happens in place: the menu becomes the field, Finder-style.
            A modal would be a heavier gesture than the edit deserves, and a
            native prompt() would block the webview's event loop the same way
            confirm() would. The extension is not shown because it is not
            editable — renaming must not be able to turn a .wav into a .txt. --%>
      <input
        type="text"
        data-ctx-rename-input
        hidden
        aria-label="New name"
        autocomplete="off"
        spellcheck="false"
        class="w-full border-0 bg-base-200 px-3 py-1.5 font-mono text-xs focus:outline-none"
      />
    </div>
    """
  end

  attr :myself, :any, required: true

  attr :trim_clip, :any,
    required: true,
    doc: "%{id, source, offset_ms, duration_ms, total_ms} being trimmed, or nil"

  @doc """
  Trim a clip to a window of its source.

  **Non-destructive, and the copy says so where it is read rather than only
  here.** The window belongs to the clip: the file on disk is untouched, the
  same source can sit in one mix twice trimmed two different ways, and re-adding
  it brings the whole thing back.

  Two numbers rather than a waveform region for the first version. The source
  trim on the detail pane has a draggable waveform (`wave_trim.js`) and this
  deliberately does not reuse it yet: that hook is bound to the selected
  SOURCE's canvas, and pointing it at a clip means teaching it a second subject.
  Numbers are honest, testable, and wrong for nobody — a region selector is the
  upgrade, not the requirement.
  """
  def trim_clip_modal(assigns) do
    ~H"""
    <div
      :if={@trim_clip}
      class="fixed inset-0 z-50"
      phx-window-keydown="close_trim_clip"
      phx-key="escape"
      phx-target={@myself}
    >
      <button
        type="button"
        phx-click="close_trim_clip"
        phx-target={@myself}
        aria-label="Close"
        class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
      >
      </button>

      <div
        id="studio-trim-clip"
        role="dialog"
        aria-modal="true"
        aria-label="Trim clip"
        class="ic-panel absolute left-1/2 top-1/2 w-80 max-w-[90vw] -translate-x-1/2 -translate-y-1/2 p-5"
      >
        <p class="ic-eyebrow">Trim clip</p>
        <h2 class="mt-1 truncate font-display text-lg font-black tracking-tight">
          {@trim_clip.source}
        </h2>

        <form phx-submit="apply_trim_clip" phx-target={@myself} class="mt-4 flex flex-col gap-3">
          <label class="flex flex-col gap-1">
            <span class="font-mono text-[10px] uppercase tracking-widest text-base-content/45">
              Start into the source (ms)
            </span>
            <input
              type="number"
              name="offset_ms"
              min="0"
              step="1"
              value={round(@trim_clip.offset_ms)}
              class="input input-bordered input-sm font-mono text-xs"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span class="font-mono text-[10px] uppercase tracking-widest text-base-content/45">
              Length (ms)
            </span>
            <input
              type="number"
              name="duration_ms"
              min="1"
              step="1"
              value={round(@trim_clip.duration_ms)}
              class="input input-bordered input-sm font-mono text-xs"
            />
          </label>

          <p :if={@trim_clip.total_ms} class="font-mono text-[10px] text-base-content/45">
            Source is {ms(@trim_clip.total_ms)} long.
          </p>

          <%!-- Said here because it is the question the control raises: people
                expect a trim to cut a file. This one does not. --%>
          <p class="border-l-2 border-primary pl-2 text-[11px] leading-snug text-base-content/60">
            The file on disk is not touched. Only this clip's slice of it changes,
            and ⌘Z puts it back.
          </p>

          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="close_trim_clip"
              phx-target={@myself}
              class="btn btn-ghost btn-xs font-mono uppercase"
            >
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-xs font-mono uppercase">Trim</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  @doc """
  Assign-on-render: offered rather than imposed, because the render is already
  in the library either way.
  """
  attr :myself, :any, required: true
  attr :assign_render, :any, required: true, doc: "the render awaiting a routing choice, or nil"

  def assign_render_modal(assigns) do
    ~H"""
    <%!-- Assign-on-render. Offered rather than imposed: the render is already
          in the library either way, so "Not now" costs nothing — it just
          means "not routed yet", and Settings → Notify can do it later. --%>
    <div
      :if={@assign_render}
      class="fixed inset-0 z-50"
      phx-window-keydown="close_assign"
      phx-key="escape"
      phx-target={@myself}
    >
      <button
        type="button"
        phx-click="close_assign"
        phx-target={@myself}
        aria-label="Close"
        class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
      >
      </button>
      <div class="pointer-events-none absolute inset-0 grid place-items-center p-4">
        <div class="pointer-events-auto w-full max-w-md border-2 border-base-content/30 bg-base-100 shadow-2xl">
          <header class="ic-scanlines relative border-b-2 border-base-content/20 px-5 py-3">
            <p class="ic-eyebrow">Rendered</p>
            <h3 class="truncate font-display text-lg font-black uppercase tracking-tight">
              {Path.rootname(@assign_render)}
            </h3>
          </header>

          <form phx-submit="assign_render" phx-target={@myself} class="space-y-4 p-5">
            <input type="hidden" name="name" value={@assign_render} />

            <div>
              <label
                for="assign-render-key"
                class="font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40"
              >
                Play it for
              </label>
              <select
                id="assign-render-key"
                name="key"
                class="select select-bordered mt-1 w-full font-mono text-xs"
              >
                <option :for={{label, key} <- Sound.route_options()} value={key}>{label}</option>
              </select>
            </div>

            <p class="font-mono text-[10px] leading-relaxed text-base-content/40">
              It is already in your sound library — this just points a
              notification at it. The built-in chime is left alone, so you can
              change your mind any time in Settings → Notify.
            </p>

            <div class="flex flex-wrap gap-2">
              <button class="rounded-xs bg-primary px-4 py-2 font-display text-sm font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85">
                Assign
              </button>
              <button
                type="button"
                phx-click="close_assign"
                phx-target={@myself}
                class="rounded-xs border-2 border-base-content/20 px-4 py-2 font-mono text-sm transition hover:border-base-content/40"
              >
                Not now
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :info, :any, required: true, doc: "the source being inspected, or nil"

  @doc "File info — a modal rather than a bigger menu, because a path is long."
  def info_modal(assigns) do
    ~H"""
    <%!-- Info. A modal rather than a bigger menu: a path is long, and the
          point of it is being able to read (and select) the whole thing. --%>
    <div
      :if={@info}
      class="fixed inset-0 z-50"
      phx-window-keydown="close_info"
      phx-key="escape"
      phx-target={@myself}
    >
      <button
        type="button"
        phx-click="close_info"
        phx-target={@myself}
        aria-label="Close info"
        class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
      >
      </button>
      <div class="pointer-events-none absolute inset-0 grid place-items-center p-4">
        <div class="pointer-events-auto w-full max-w-lg border-2 border-base-content/30 bg-base-100 shadow-2xl">
          <header class="ic-scanlines relative flex items-center justify-between border-b-2 border-base-content/20 px-5 py-3">
            <div class="relative z-[2] min-w-0">
              <p class="ic-eyebrow">{@info.kind}</p>
              <h3 class="truncate font-display text-lg font-black uppercase tracking-tight">
                {@info.label}
              </h3>
            </div>
            <button
              type="button"
              phx-click="close_info"
              phx-target={@myself}
              aria-label="Close info"
              class="relative z-[2] grid size-8 shrink-0 place-items-center border-2 border-base-content/30 text-lg leading-none transition hover:border-primary hover:text-primary"
            >
              ×
            </button>
          </header>

          <dl class="space-y-3 p-5 font-mono text-xs">
            <div>
              <dt class="text-base-content/40">On disk</dt>
              <%!-- `select-all` so one click grabs the whole path; `break-all`
                    because a deep workspace path has no spaces to wrap on. --%>
              <dd class="mt-0.5 select-all break-all text-base-content/80">{@info.path}</dd>
            </div>
            <div class="grid grid-cols-3 gap-3">
              <div>
                <dt class="text-base-content/40">Size</dt>
                <dd class="mt-0.5">{humanize_bytes(@info.size)}</dd>
              </div>
              <div>
                <dt class="text-base-content/40">Length</dt>
                <dd class="mt-0.5">{ms(@info.duration_ms)}</dd>
              </div>
              <div>
                <dt class="text-base-content/40">Format</dt>
                <dd class="mt-0.5">
                  {if @info.rate, do: "#{@info.rate} Hz · #{@info.channels} ch", else: "—"}
                </dd>
              </div>
            </div>
            <p :if={@info.note} class="text-warning">{@info.note}</p>
          </dl>
        </div>
      </div>
    </div>
    """
  end
end
