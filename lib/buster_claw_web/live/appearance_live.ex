defmodule BusterClawWeb.AppearanceLive do
  @moduledoc """
  Appearance settings (Settings → Appearance sub-tab). Theme selection is
  applied client-side: the buttons dispatch `phx:set-theme`, which the inline
  script in `root.html.heex` persists to `localStorage["phx:theme"]` and applies
  via the `data-theme` attribute.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Appearance

  # Swatch metadata for the terminal-theme picker. The actual xterm palettes
  # live in `assets/js/app.js` (TERM_THEMES); `key` must match. bg/fg/accent are
  # only used to render the preview chip. "industrial" mirrors the app's tokens.
  @terminal_themes [
    %{key: "industrial", label: "Industrial", bg: "#121212", fg: "#f4f1ea", accent: "#ff4d1c"},
    %{key: "dracula", label: "Dracula", bg: "#282a36", fg: "#f8f8f2", accent: "#bd93f9"},
    %{key: "solarized", label: "Solarized", bg: "#002b36", fg: "#839496", accent: "#2aa198"},
    %{key: "nord", label: "Nord", bg: "#2e3440", fg: "#d8dee9", accent: "#88c0d0"},
    %{key: "gruvbox", label: "Gruvbox", bg: "#282828", fg: "#ebdbb2", accent: "#fabd2f"},
    %{key: "monokai", label: "Monokai", bg: "#272822", fg: "#f8f8f2", accent: "#a6e22e"},
    %{key: "tokyo-night", label: "Tokyo Night", bg: "#1a1b26", fg: "#c0caf5", accent: "#7aa2f7"},
    %{key: "light", label: "Light", bg: "#fafafa", fg: "#1a1a1a", accent: "#2563eb"},
    %{key: "matrix", label: "Matrix", bg: "#000000", fg: "#00ff41", accent: "#00ff41"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Appearance")
     |> assign(:terminal_themes, @terminal_themes)
     |> assign(:home_bg, Appearance.home_background_state())
     |> assign_slots()
     |> allow_upload(:terminal_background,
       accept: Appearance.accepted_extensions(),
       max_entries: 1,
       max_file_size: 8_000_000
     )
     |> allow_upload(:home_background,
       accept: Appearance.accepted_extensions(),
       max_entries: 1,
       max_file_size: 8_000_000
     )}
  end

  @impl true
  def handle_event("validate_background", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_background", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :terminal_background, ref)}
  end

  def handle_event("save_background", _params, socket) do
    case Appearance.next_empty_slot() do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "All #{Appearance.max_slots()} slots are full — remove one first."
         )}

      slot ->
        consumed =
          consume_uploaded_entries(socket, :terminal_background, fn %{path: path}, entry ->
            {:ok, Appearance.put_terminal_background(slot, path, entry.client_name)}
          end)

        socket =
          case consumed do
            [{:ok, _url}] -> socket |> assign_slots() |> put_flash(:info, "Background added.")
            [{:error, _reason}] -> put_flash(socket, :error, "That image type isn't supported.")
            [] -> put_flash(socket, :error, "Choose an image first.")
          end

        {:noreply, socket}
    end
  end

  def handle_event("set_active", %{"slot" => slot}, socket) do
    case Appearance.set_active_slot(String.to_integer(slot)) do
      {:ok, _url} ->
        {:noreply, socket |> assign_slots() |> put_flash(:info, "Background applied.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That slot is empty.")}
    end
  end

  def handle_event("remove_background", %{"slot" => slot}, socket) do
    Appearance.clear_slot(String.to_integer(slot))
    {:noreply, socket |> assign_slots() |> put_flash(:info, "Background removed.")}
  end

  # --- homepage background ---

  def handle_event("set_home_bg", %{"mode" => mode}, socket) do
    case Appearance.set_home_background_mode(mode) do
      {:ok, _mode} ->
        {:noreply, socket |> assign_home_bg() |> put_flash(:info, "Homepage background updated.")}

      {:error, :no_image} ->
        {:noreply, put_flash(socket, :error, "Upload an image first.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unknown background.")}
    end
  end

  def handle_event("validate_home_bg", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_home_bg", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :home_background, ref)}

  def handle_event("save_home_bg", _params, socket) do
    consumed =
      consume_uploaded_entries(socket, :home_background, fn %{path: path}, entry ->
        {:ok, Appearance.put_home_background_image(path, entry.client_name)}
      end)

    socket =
      case consumed do
        [{:ok, _url}] -> socket |> assign_home_bg() |> put_flash(:info, "Homepage image applied.")
        [{:error, _reason}] -> put_flash(socket, :error, "That image type isn't supported.")
        [] -> put_flash(socket, :error, "Choose an image first.")
      end

    {:noreply, socket}
  end

  def handle_event("remove_home_bg", _params, socket) do
    Appearance.clear_home_background_image()
    {:noreply, socket |> assign_home_bg() |> put_flash(:info, "Homepage image removed.")}
  end

  def handle_event("toggle_home_custom", _params, socket) do
    Appearance.set_home_background_custom(!socket.assigns.home_bg.custom)
    {:noreply, assign_home_bg(socket)}
  end

  def handle_event("set_home_colors", %{"c1" => c1, "c2" => c2, "c3" => c3}, socket) do
    Appearance.set_home_background_colors([c1, c2, c3])
    {:noreply, assign_home_bg(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:appearance} />

        <div class="grid items-start gap-6 lg:grid-cols-2">
          <section class="ic-panel space-y-4 p-6">
            <h2 class="ic-eyebrow">Theme</h2>
            <p class="max-w-2xl text-sm leading-7 text-base-content/70">
              Choose how Buster Claw looks. <span class="font-semibold">System</span>
              follows your operating system's appearance.
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click={JS.dispatch("phx:set-theme")}
                data-phx-theme="system"
                class={theme_btn()}
              >
                <.icon name="hero-computer-desktop" class="size-4" /> System
              </button>
              <button
                type="button"
                phx-click={JS.dispatch("phx:set-theme")}
                data-phx-theme="light"
                class={theme_btn()}
              >
                <.icon name="hero-sun" class="size-4" /> Light
              </button>
              <button
                type="button"
                phx-click={JS.dispatch("phx:set-theme")}
                data-phx-theme="dark"
                class={theme_btn()}
              >
                <.icon name="hero-moon" class="size-4" /> Dark
              </button>
            </div>
          </section>

          <section class="ic-panel space-y-4 p-6">
            <h2 class="ic-eyebrow">Terminal theme</h2>
            <p class="max-w-2xl text-sm leading-7 text-base-content/70">
              Color scheme for the in-app terminal — background, text, cursor, and ANSI colors.
              Applies to open terminals immediately.
            </p>
            <div
              id="terminal-theme-picker"
              phx-hook="TermThemePicker"
              class="grid gap-3 sm:grid-cols-2"
            >
              <button
                :for={t <- @terminal_themes}
                type="button"
                phx-click={JS.dispatch("bc:set-term-theme")}
                data-term-theme={t.key}
                title={t.label}
                class="group flex items-center gap-3 rounded-lg border-2 border-base-content/20 p-2.5 text-left transition hover:border-primary focus:outline-none"
              >
                <span
                  class="flex size-11 shrink-0 flex-col items-start justify-center gap-1 rounded-md px-2 font-mono"
                  style={"background:#{t.bg}"}
                >
                  <span class="text-xs font-bold leading-none" style={"color:#{t.fg}"}>$ ls</span>
                  <span class="h-1.5 w-5 rounded-full" style={"background:#{t.accent}"}></span>
                </span>
                <span class="min-w-0">
                  <span class="block text-sm font-semibold">{t.label}</span>
                  <span class="block font-mono text-xs text-base-content/55">{t.key}</span>
                </span>
              </button>
            </div>
          </section>
        </div>

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Terminal background</h2>
          <p class="max-w-2xl text-sm leading-7 text-base-content/70">
            Save up to {Appearance.max_slots()} images and switch the one painted
            behind the in-app terminal. In a split, the active image spans both
            panes as one continuous background.
          </p>

          <div class="grid gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <div
              :for={slot <- @slots}
              class={[
                "flex aspect-video flex-col overflow-hidden rounded-lg border-2",
                if(slot.active, do: "border-primary", else: "border-base-content/20")
              ]}
            >
              <div :if={slot.filled} class="flex min-h-0 flex-1 flex-col">
                <div
                  class="relative flex-1 bg-cover bg-center"
                  style={"background-image:url('#{slot.url}')"}
                >
                  <span
                    :if={slot.active}
                    class="absolute left-1.5 top-1.5 rounded bg-primary px-1.5 py-0.5 text-xs font-bold text-primary-content"
                  >
                    Active
                  </span>
                </div>
                <div class="flex items-center justify-between border-t border-base-content/15 bg-base-100 px-2 py-1.5">
                  <button
                    :if={!slot.active}
                    type="button"
                    phx-click="set_active"
                    phx-value-slot={slot.slot}
                    class="rounded px-2 py-1 text-xs font-semibold transition hover:bg-base-200"
                  >
                    Use
                  </button>
                  <span :if={slot.active} class="px-2 py-1 text-xs text-base-content/50">In use</span>
                  <button
                    type="button"
                    phx-click="remove_background"
                    phx-value-slot={slot.slot}
                    class="rounded px-2 py-1 text-xs text-base-content/60 transition hover:text-error"
                  >
                    Remove
                  </button>
                </div>
              </div>

              <div :if={!slot.filled} class="flex min-h-0 flex-1 flex-col">
                <div class="flex flex-1 items-center justify-center text-xs text-base-content/40">
                  Empty
                </div>
                <div class="border-t border-base-content/15 bg-base-100 px-2 py-1.5 text-center text-xs text-base-content/40">
                  Slot {slot.slot}
                </div>
              </div>
            </div>
          </div>

          <form
            id="terminal-background-form"
            phx-change="validate_background"
            phx-submit="save_background"
            class="space-y-3"
          >
            <label
              phx-drop-target={@uploads.terminal_background.ref}
              class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-base-content/25 px-6 py-8 text-center transition hover:border-primary"
            >
              <.icon name="hero-photo" class="size-7 text-base-content/50" />
              <span class="text-sm font-semibold">Drop an image here, or click to choose</span>
              <span class="font-mono text-xs text-base-content/50">
                PNG, JPG, WEBP, GIF · up to 8 MB · fills the next open slot
              </span>
              <.live_file_input upload={@uploads.terminal_background} class="sr-only" />
            </label>

            <div
              :for={entry <- @uploads.terminal_background.entries}
              class="flex items-center gap-3 rounded-lg border-2 border-base-content/15 p-2.5"
            >
              <.live_img_preview entry={entry} class="h-12 w-20 shrink-0 rounded object-cover" />
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-semibold">{entry.client_name}</div>
                <div class="font-mono text-xs text-base-content/50">{entry.progress}%</div>
              </div>
              <button
                type="button"
                phx-click="cancel_background"
                phx-value-ref={entry.ref}
                aria-label="Cancel upload"
                class="grid size-8 place-items-center rounded-sm text-base-content/60 transition hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p
              :for={err <- upload_errors(@uploads.terminal_background)}
              class="text-sm text-error"
            >
              {upload_error_to_string(err)}
            </p>

            <p :if={Enum.all?(@slots, & &1.filled)} class="text-sm text-base-content/60">
              All {Appearance.max_slots()} slots are full — remove one to add another.
            </p>

            <button
              type="submit"
              disabled={@uploads.terminal_background.entries == [] or Enum.all?(@slots, & &1.filled)}
              class="inline-flex items-center gap-2 rounded border-2 border-primary px-4 py-2 text-sm font-semibold text-primary transition hover:bg-primary hover:text-primary-content disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Add background
            </button>
          </form>
        </section>

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Homepage background</h2>
          <p class="max-w-2xl text-sm leading-7 text-base-content/70">
            Choose the animated shader that drifts behind the home chat, or use your
            own image. Shaders need WebGPU (the desktop app); if it's unavailable the
            background is simply blank.
          </p>

          <div class="flex flex-wrap gap-2">
            <button
              :for={design <- home_shader_options()}
              type="button"
              phx-click="set_home_bg"
              phx-value-mode={design.key}
              class={home_opt_btn(@home_bg.mode == design.key)}
            >
              <.icon name="hero-sparkles" class="size-4" /> {design.label}
            </button>
            <button
              type="button"
              phx-click="set_home_bg"
              phx-value-mode="image"
              disabled={is_nil(@home_bg.image_url)}
              title={is_nil(@home_bg.image_url) && "Upload an image first"}
              class={
                home_opt_btn(@home_bg.mode == "image") ++
                  ["disabled:cursor-not-allowed disabled:opacity-40"]
              }
            >
              <.icon name="hero-photo" class="size-4" /> Image
            </button>
          </div>

          <%!-- Live preview + custom palette (applies to the selected shader). --%>
          <div class="flex flex-wrap items-start gap-4">
            <div
              :if={@home_bg.mode != "image"}
              id={"shader-preview-#{@home_bg.mode}-#{@home_bg.custom}"}
              phx-hook="ShaderPreview"
              phx-update="ignore"
              data-shader={@home_bg.mode}
              data-custom={to_string(@home_bg.custom)}
              class="h-28 w-44 shrink-0 overflow-hidden rounded-lg border-2 border-base-content/20"
              aria-label="Shader preview"
            >
              <canvas class="block h-full w-full"></canvas>
            </div>

            <div class="min-w-0 flex-1 space-y-3">
              <label class="inline-flex cursor-pointer items-center gap-2 text-sm font-semibold">
                <input
                  type="checkbox"
                  checked={@home_bg.custom}
                  phx-click="toggle_home_custom"
                  class="size-4 accent-primary"
                /> Use custom colors
              </label>

              <form :if={@home_bg.custom} phx-change="set_home_colors" class="flex flex-wrap gap-4">
                <label
                  :for={{hex, i} <- Enum.with_index(@home_bg.colors)}
                  class="flex items-center gap-2"
                >
                  <input
                    type="color"
                    id={"home-color-#{i + 1}"}
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

              <p :if={!@home_bg.custom} class="text-sm text-base-content/50">
                Using the design's built-in colors. Turn on custom colors to pick your own three.
              </p>
            </div>
          </div>

          <div
            :if={@home_bg.image_url}
            class="flex items-center gap-3 rounded-lg border-2 border-base-content/15 p-2.5"
          >
            <div
              class="aspect-video w-32 shrink-0 rounded bg-cover bg-center"
              style={"background-image:url('#{@home_bg.image_url}')"}
            >
            </div>
            <div class="min-w-0 flex-1">
              <div class="text-sm font-semibold">Your homepage image</div>
              <div class="font-mono text-xs text-base-content/50">
                {if @home_bg.mode == "image",
                  do: "In use",
                  else: "Uploaded — select \"Image\" to use it"}
              </div>
            </div>
            <button
              type="button"
              phx-click="remove_home_bg"
              class="rounded px-2 py-1 text-xs text-base-content/60 transition hover:text-error"
            >
              Remove
            </button>
          </div>

          <form
            id="home-background-form"
            phx-change="validate_home_bg"
            phx-submit="save_home_bg"
            class="space-y-3"
          >
            <label
              phx-drop-target={@uploads.home_background.ref}
              class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-base-content/25 px-6 py-8 text-center transition hover:border-primary"
            >
              <.icon name="hero-photo" class="size-7 text-base-content/50" />
              <span class="text-sm font-semibold">Drop an image here, or click to choose</span>
              <span class="font-mono text-xs text-base-content/50">
                PNG, JPG, WEBP, GIF · up to 8 MB · becomes your homepage background
              </span>
              <.live_file_input upload={@uploads.home_background} class="sr-only" />
            </label>

            <div
              :for={entry <- @uploads.home_background.entries}
              class="flex items-center gap-3 rounded-lg border-2 border-base-content/15 p-2.5"
            >
              <.live_img_preview entry={entry} class="h-12 w-20 shrink-0 rounded object-cover" />
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-semibold">{entry.client_name}</div>
                <div class="font-mono text-xs text-base-content/50">{entry.progress}%</div>
              </div>
              <button
                type="button"
                phx-click="cancel_home_bg"
                phx-value-ref={entry.ref}
                aria-label="Cancel upload"
                class="grid size-8 place-items-center rounded-sm text-base-content/60 transition hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p :for={err <- upload_errors(@uploads.home_background)} class="text-sm text-error">
              {upload_error_to_string(err)}
            </p>

            <button
              type="submit"
              disabled={@uploads.home_background.entries == []}
              class="inline-flex items-center gap-2 rounded border-2 border-primary px-4 py-2 text-sm font-semibold text-primary transition hover:bg-primary hover:text-primary-content disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Use image
            </button>
          </form>
        </section>
      </section>
    </Layouts.app>
    """
  end

  @home_shader_labels %{
    "smoke" => "Smoke",
    "aurora" => "Aurora",
    "waves" => "Waves",
    "lava" => "Lava"
  }
  defp home_shader_options,
    do:
      Enum.map(
        Appearance.home_shaders(),
        &%{key: &1, label: Map.get(@home_shader_labels, &1, &1)}
      )

  defp assign_home_bg(socket), do: assign(socket, :home_bg, Appearance.home_background_state())

  defp home_opt_btn(active?) do
    [
      "inline-flex items-center gap-2 rounded border-2 px-4 py-2 text-sm font-semibold transition",
      if(active?,
        do: "border-primary bg-primary text-primary-content",
        else: "border-base-content/30 hover:border-primary hover:text-primary"
      )
    ]
  end

  defp assign_slots(socket), do: assign(socket, :slots, Appearance.slots())

  defp upload_error_to_string(:too_large), do: "That image is larger than 8 MB."
  defp upload_error_to_string(:too_many_files), do: "Choose a single image."
  defp upload_error_to_string(:not_accepted), do: "Use a PNG, JPG, WEBP, or GIF image."
  defp upload_error_to_string(_), do: "That image couldn't be uploaded."

  defp theme_btn,
    do:
      "inline-flex items-center gap-2 rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:border-primary hover:text-primary"
end
