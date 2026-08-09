defmodule BusterClawWeb.AppearanceLive do
  @moduledoc """
  Appearance settings (Settings → Appearance sub-tab).

  Backgrounds are **one catalog, shown once**: `off`, every shader (built-in and
  workspace), and the shared image pool. It scrolls in the left column; the two
  surfaces that have a background — Homepage and Terminal — sit in the right
  column, each showing a live preview of what it is actually running. Every
  catalog row carries a Home and a Terminal button, and that is the whole
  interaction: one plain click, no drag. The same option can back both surfaces
  at once, which is why the catalog is a catalog and not two pickers.

  Only the two surface containers animate. A live WebGPU canvas per catalog row
  would mean a GPU device per row (`createSmoke` requests its own adapter and
  device), so a shader is named rather than pictured — the only honest preview of
  a shader is the shader, and that runs in the containers.

  App theme selection is applied client-side: the buttons dispatch
  `phx:set-theme`, which the inline script in `root.html.heex` persists to
  `localStorage["phx:theme"]` and applies via the `data-theme` attribute.

  ## The chat skin

  Also here, because this is the tab that owns how the app looks: which of
  `BusterClaw.ChatSkin`'s three looks the homepage chat wears. The dropdown
  persists on change with no Save button, matching the click-to-apply behaviour
  of everything else on this page, and it renders a live transcript preview
  beside itself — the operator is on this page, not the homepage, so a preview is
  the only way "see it immediately" can mean anything. An open homepage does
  update for real, over PubSub, at the same moment.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Appearance
  alias BusterClaw.ChatSkin

  # Swatch metadata for the terminal-theme picker. The actual xterm palettes
  # live in `assets/js/lib/theme.js` (TERM_THEMES); `key` must match. bg/fg/accent
  # are only used to render the preview chip. "industrial" mirrors the app's tokens.
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

  # `phx-value-surface` arrives as a string. Resolve it through this table rather
  # than String.to_atom on user input.
  @surface_params %{"home" => :home, "terminal" => :terminal}

  @impl true
  def mount(_params, _session, socket) do
    # This page is where the app tells you a `.wgsl` file can go in `shaders/`,
    # so this is where that folder should come into existence.
    BusterClaw.Workspace.ensure_entry("shaders")

    {:ok,
     socket
     |> assign(:page_title, "Appearance")
     |> assign(:terminal_themes, @terminal_themes)
     |> assign(:surfaces, Appearance.surfaces())
     |> assign(:chat_skins, ChatSkin.skins())
     |> assign(:chat_skin, ChatSkin.get())
     |> assign_backgrounds()
     |> allow_upload(:background,
       accept: Appearance.accepted_extensions(),
       max_entries: 1,
       max_file_size: 8_000_000
     )}
  end

  # --- assignment ----------------------------------------------------------

  @impl true
  def handle_event("assign_background", %{"surface" => surface, "option" => option}, socket) do
    case surface_param(surface) do
      nil ->
        {:noreply, socket}

      s ->
        case Appearance.set_background(s, option) do
          {:ok, _key} ->
            {:noreply,
             socket
             |> assign_backgrounds()
             |> put_flash(:info, "#{Appearance.surface_label(s)} background updated.")}

          {:error, :empty_slot} ->
            {:noreply, put_flash(socket, :error, "That slot is empty.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unknown background.")}
        end
    end
  end

  # No Save button: the change lands, the preview restyles, and any open homepage
  # restyles with it. An unknown value is dropped rather than flashed — the only
  # way to send one is to edit the select, and inventing an error message for a
  # case the UI cannot produce is worse than ignoring it.
  def handle_event("set_chat_skin", %{"skin" => skin}, socket) do
    case ChatSkin.set(skin) do
      {:ok, key} -> {:noreply, assign(socket, :chat_skin, key)}
      {:error, :invalid_skin} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_custom", %{"surface" => surface}, socket) do
    case surface_param(surface) do
      nil ->
        {:noreply, socket}

      s ->
        Appearance.set_custom(s, !socket.assigns.backgrounds[s].custom)
        {:noreply, assign_backgrounds(socket)}
    end
  end

  def handle_event(
        "set_colors",
        %{"surface" => surface, "c1" => c1, "c2" => c2, "c3" => c3},
        socket
      ) do
    case surface_param(surface) do
      nil ->
        {:noreply, socket}

      s ->
        Appearance.set_colors(s, [c1, c2, c3])
        {:noreply, assign_backgrounds(socket)}
    end
  end

  # --- the image pool ------------------------------------------------------

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :background, ref)}
  end

  def handle_event("save_upload", _params, socket) do
    consumed =
      consume_uploaded_entries(socket, :background, fn %{path: path}, entry ->
        {:ok, Appearance.put_image(path, entry.client_name)}
      end)

    socket =
      case consumed do
        [{:ok, _slot}] ->
          socket
          |> assign_backgrounds()
          |> put_flash(:info, "Image added — use its Home or Term button to apply it.")

        [{:error, :pool_full}] ->
          put_flash(socket, :error, "All #{Appearance.max_images()} slots are full.")

        [{:error, _reason}] ->
          put_flash(socket, :error, "That image type isn't supported.")

        [] ->
          put_flash(socket, :error, "Choose an image first.")
      end

    {:noreply, socket}
  end

  def handle_event("remove_image", %{"slot" => slot}, socket) do
    case parse_slot(slot) do
      nil ->
        {:noreply, socket}

      n ->
        Appearance.clear_image(n)
        {:noreply, socket |> assign_backgrounds() |> put_flash(:info, "Image removed.")}
    end
  end

  # --- render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:appearance} />

        <%!-- Two columns of equal height: the catalog scrolls inside its own
              panel on the left, the two surface panels stack on the right and
              set the height for both. --%>
        <div id="backgrounds" class="grid gap-6 lg:grid-cols-2">
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
                    phx-drop-target={@uploads.background.ref}
                    class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-base-content/25 px-4 py-6 text-center transition hover:border-primary"
                  >
                    <.icon name="hero-photo" class="size-7 text-base-content/50" />
                    <span class="text-sm font-semibold">Drop an image here, or click to choose</span>
                    <span class="font-mono text-xs text-base-content/50">
                      PNG, JPG, WEBP, GIF · up to 8 MB
                    </span>
                    <.live_file_input upload={@uploads.background} class="sr-only" />
                  </label>

                  <div
                    :for={entry <- @uploads.background.entries}
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

                  <p :for={err <- upload_errors(@uploads.background)} class="text-sm text-error">
                    {upload_error_to_string(err)}
                  </p>

                  <p :if={@pool_full} class="text-sm text-base-content/60">
                    All {Appearance.max_images()} image slots are full — remove one to add another.
                  </p>

                  <button
                    type="submit"
                    disabled={@uploads.background.entries == [] or @pool_full}
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

          <div class="space-y-6">
            <.surface_target
              :for={surface <- @surfaces}
              surface={surface}
              bg={@backgrounds[surface]}
            />
          </div>
        </div>

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

        <section class="ic-panel space-y-4 p-6" aria-labelledby="chat-skin-heading">
          <h2 id="chat-skin-heading" class="ic-eyebrow">Chat theme</h2>
          <p class="max-w-2xl text-sm leading-7 text-base-content/70">
            How the chat on the homepage looks. The change applies the moment you pick it —
            here, and in an open homepage.
          </p>

          <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,18rem)_minmax(0,1fr)]">
            <form phx-change="set_chat_skin" class="space-y-3">
              <label for="chat-skin-select" class="sr-only">Chat theme</label>
              <select
                id="chat-skin-select"
                name="skin"
                class="w-full rounded border-2 border-base-content/25 bg-base-100 px-3 py-2 text-sm font-semibold focus:border-primary focus:outline-none"
              >
                <option :for={skin <- @chat_skins} value={skin.key} selected={skin.key == @chat_skin}>
                  {skin.label}
                </option>
              </select>
              <p
                :for={skin <- @chat_skins}
                :if={skin.key == @chat_skin}
                data-chat-skin-blurb
                class="text-sm leading-6 text-base-content/70"
              >
                {skin.blurb}
              </p>
            </form>

            <div class="space-y-2">
              <div class="rounded border-2 border-base-content/20 bg-base-100">
                <BusterClawWeb.ChatPanel.transcript_preview skin={@chat_skin} />
              </div>
              <%!-- Said rather than implied. The composer's form carries live hooks
                    and a `chat_send` submit that would crash this page, so the
                    preview is the transcript; and the skins' translucency and
                    shadow rules describe a panel over the homepage's shader, which
                    a settings page does not have. Both are real gaps, and a
                    preview that quietly omitted them would be the kind of promise
                    this app keeps getting wrong. --%>
              <p class="text-xs leading-5 text-base-content/55">
                The transcript only — the message box and the panel's own edges are shown on the
                homepage.
              </p>
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  # A surface's panel: what it's running now, live, plus its palette.
  attr :surface, :atom, required: true
  attr :bg, :map, required: true

  defp surface_target(assigns) do
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
          <% @bg.kind == :shader -> %>
            <div
              id={"#{@surface}-surface-preview-#{@bg.shader}-#{@bg.custom}"}
              phx-hook="ShaderPreview"
              phx-update="ignore"
              data-shader={@bg.shader}
              data-shader-source={@bg.source_url}
              data-custom={to_string(@bg.custom)}
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

      <div :if={@bg.kind == :shader} class="space-y-3 border-t-2 border-base-content/15 p-4">
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
      <span class="text-sm font-semibold">{@opt.label}</span>

      <span
        :if={@assigned != []}
        class="rounded bg-primary px-1.5 py-0.5 text-[0.625rem] font-bold uppercase tracking-wide text-primary-content"
      >
        {assigned_badge(@assigned)}
      </span>

      <span class="ml-auto flex shrink-0 items-center gap-0.5 border-l-2 border-base-content/15 pl-1.5">
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

  # --- helpers -------------------------------------------------------------

  defp assign_backgrounds(socket) do
    backgrounds = Map.new(Appearance.surfaces(), &{&1, Appearance.background(&1)})
    # The catalog renders in two shapes — named chips for off/shaders, thumbnails
    # for the image pool — so split it once here rather than branching per tile.
    {shader_options, image_options} =
      Enum.split_with(Appearance.options(), &(&1.kind != :image))

    socket
    |> assign(:backgrounds, backgrounds)
    |> assign(:shader_options, shader_options)
    |> assign(:image_options, image_options)
    |> assign(:pool_full, Appearance.pool_full?())
  end

  defp surface_param(value) when is_binary(value), do: Map.get(@surface_params, value)
  defp surface_param(_value), do: nil

  # Safely parse a `phx-value-slot` into an integer; a crafted/non-integer value
  # yields nil (handler no-ops) rather than raising and crashing the LiveView.
  defp parse_slot(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_slot(_value), do: nil

  # Which surfaces currently run this option, so the tile can badge itself.
  defp assigned_to(backgrounds, opt) do
    Enum.filter(Appearance.surfaces(), fn surface ->
      Appearance.option_key(backgrounds[surface]) == opt.key
    end)
  end

  defp assigned_badge(surfaces), do: Enum.map_join(surfaces, " · ", &short_label/1)

  defp short_label(:home), do: "Home"
  defp short_label(:terminal), do: "Term"

  defp current_label(%{kind: :none}), do: "Off"
  defp current_label(%{kind: :image, slot: slot}), do: "Image #{slot}"
  defp current_label(%{kind: :shader, shader: shader}), do: shader

  defp upload_error_to_string(:too_large), do: "That image is larger than 8 MB."
  defp upload_error_to_string(:too_many_files), do: "Choose a single image."
  defp upload_error_to_string(:not_accepted), do: "Use a PNG, JPG, WEBP, or GIF image."
  defp upload_error_to_string(_), do: "That image couldn't be uploaded."

  defp theme_btn,
    do:
      "inline-flex items-center gap-2 rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:border-primary hover:text-primary"
end
