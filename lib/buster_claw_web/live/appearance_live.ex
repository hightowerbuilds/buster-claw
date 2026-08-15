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

  ## The chat's look

  Also here, because this is the tab that owns how the app looks: two independent
  axes for the homepage chat — which of `BusterClaw.ChatSkin`'s three looks it
  wears, and how large `BusterClaw.ChatTextSize` makes its text. Two settings
  rather than a single list of twelve, because wanting bigger text should not cost
  you the look you picked; they multiply in the CSS.

  Both dropdowns persist on change with no Save button, matching the
  click-to-apply behaviour of everything else on this page, and both drive the
  same live transcript preview — the operator is on this page, not the homepage,
  so a preview is the only way "see it immediately" can mean anything. An open
  homepage does update for real, over PubSub, at the same moment.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Appearance
  alias BusterClaw.ChatSkin
  alias BusterClaw.ChatTextSize
  alias BusterClaw.TerminalTheme

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
     |> assign_terminal_themes()
     |> assign(:surfaces, Appearance.surfaces())
     |> assign(:chat_skins, ChatSkin.skins())
     |> assign(:chat_skin, ChatSkin.get())
     |> assign(:chat_text_sizes, ChatTextSize.sizes())
     |> assign(:chat_text_size, ChatTextSize.get())
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

  # Same shape as the skin above, and the same reason for having no Save button.
  def handle_event("set_chat_text_size", %{"size" => size}, socket) do
    case ChatTextSize.set(size) do
      {:ok, key} -> {:noreply, assign(socket, :chat_text_size, key)}
      {:error, :invalid_size} -> {:noreply, socket}
    end
  end

  # --- the custom terminal theme -------------------------------------------

  # The spectrum slider. One number in, a complete 21-colour palette out — which is
  # what keeps the invariant that a custom theme is never half-applied (background
  # yours, `ls` xterm's). The hue tints the surfaces fully and the program colours
  # only slightly, so dragging it changes the terminal's whole mood and `red` stays
  # red. Saved on every change, so the open terminal follows the drag.
  def handle_event("generate_custom_theme", %{"hue" => hue}, socket) do
    case Integer.parse(hue) do
      {hue, ""} ->
        {:noreply,
         socket
         |> assign(:custom_hue, hue)
         |> assign(:custom_error, nil)
         |> save_draft(TerminalTheme.generate(hue), hue)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("edit_custom_theme", _params, socket) do
    case TerminalTheme.custom() do
      nil -> {:noreply, socket}
      theme -> {:noreply, open_draft(socket, theme)}
    end
  end

  def handle_event("close_custom_theme", _params, socket) do
    {:noreply, assign(socket, custom_draft: nil, custom_error: nil)}
  end

  # One form carrying the whole palette, saved on every change, so the terminal
  # restyles while the colour picker is still open. No Save button for the same
  # reason nothing else on this page has one.
  #
  # The params ARE the palette — every input is named for its field — so there is
  # no per-field event to keep in step with the field list. `_target` is dropped
  # unread: it says which input moved, and this saves all of them anyway.
  def handle_event("save_custom_theme", params, socket) do
    name = Map.get(params, "name", "")
    colors = Map.drop(params, ["_target", "name"])

    {:noreply, socket |> assign(:custom_name, name) |> save_draft(colors)}
  end

  def handle_event("delete_custom_theme", _params, socket) do
    TerminalTheme.clear_custom()

    {:noreply,
     socket
     |> assign(custom_draft: nil, custom_error: nil)
     |> assign_terminal_themes()
     |> push_event("bc-term-custom", %{palette: nil})
     |> put_flash(:info, "Custom terminal theme deleted.")}
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

  # Lay an image-reactive shader over the image a surface is already showing, or
  # take it off again ("" -> back to the plain image). The slot comes from what
  # the surface is showing rather than the form, so the picker cannot be used to
  # point a surface at a different image by accident.
  def handle_event("set_overlay", %{"surface" => surface, "shader" => shader}, socket) do
    with s when not is_nil(s) <- surface_param(surface),
         %{slot: slot} when is_integer(slot) <- socket.assigns.backgrounds[s] do
      key = if shader == "", do: "image:#{slot}", else: "image:#{slot}+#{shader}"

      case Appearance.set_background(s, key) do
        {:ok, _} ->
          {:noreply, assign_backgrounds(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, overlay_error(reason))}
      end
    else
      _ -> {:noreply, socket}
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
            <BusterClawWeb.SurfacePanel.surface_target
              :for={surface <- @surfaces}
              surface={surface}
              bg={@backgrounds[surface]}
              overlays={@overlays}
            />
          </div>
        </div>

        <%!-- Left cell stacks the two look-and-feel panels; right cell is the tall
              terminal palette. A stack rather than three grid children on purpose:
              auto-placement would put the third one in column 1 ROW 2, below the
              terminal column's baseline, which is the empty gap this arrangement
              exists to close. --%>
        <div class="grid items-start gap-6 lg:grid-cols-2">
          <div class="space-y-6">
            <section class="ic-panel space-y-4 p-6">
              <h2 class="ic-eyebrow">Theme</h2>
              <p class="text-sm leading-7 text-base-content/70">
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

            <%!-- Compact by design: this now lives in half a column under Theme
                  rather than full-width below everything. The two dropdowns share a
                  row, their copy is one line each, and the preview takes the width
                  it is given — a transcript is narrow anyway, so a half column shows
                  it honestly. --%>
            <section class="ic-panel space-y-3 p-6" aria-labelledby="chat-skin-heading">
              <h2 id="chat-skin-heading" class="ic-eyebrow">Chat theme</h2>
              <p class="text-sm leading-7 text-base-content/70">
                How the chat on the homepage looks. Applies the moment you pick it — here, and
                in an open homepage.
              </p>

              <div class="grid gap-3 sm:grid-cols-2">
                <form phx-change="set_chat_skin" class="space-y-2">
                  <label for="chat-skin-select" class="ic-eyebrow block">Theme</label>
                  <select
                    id="chat-skin-select"
                    name="skin"
                    class="w-full rounded border-2 border-base-content/25 bg-base-100 px-3 py-2 text-sm font-semibold focus:border-primary focus:outline-none"
                  >
                    <option
                      :for={skin <- @chat_skins}
                      value={skin.key}
                      selected={skin.key == @chat_skin}
                    >
                      {skin.label}
                    </option>
                  </select>
                </form>

                <%!-- A separate axis, on purpose: bigger text should not cost you the
                      look you picked. The two multiply — every skin's font sizes are
                      written as a multiple of this one number. --%>
                <form phx-change="set_chat_text_size" class="space-y-2">
                  <label for="chat-text-size-select" class="ic-eyebrow block">Text size</label>
                  <select
                    id="chat-text-size-select"
                    name="size"
                    class="w-full rounded border-2 border-base-content/25 bg-base-100 px-3 py-2 text-sm font-semibold focus:border-primary focus:outline-none"
                  >
                    <option
                      :for={size <- @chat_text_sizes}
                      value={size.key}
                      selected={size.key == @chat_text_size}
                    >
                      {size.label} · {ChatTextSize.percent(size.key)}%
                    </option>
                  </select>
                </form>
              </div>

              <p
                :for={skin <- @chat_skins}
                :if={skin.key == @chat_skin}
                data-chat-skin-blurb
                class="text-sm leading-6 text-base-content/70"
              >
                {skin.blurb} Text size scales what you read, not the buttons.
              </p>

              <div class="rounded border-2 border-base-content/20 bg-base-100">
                <BusterClawWeb.ChatPanel.transcript_preview
                  skin={@chat_skin}
                  text_size={@chat_text_size}
                />
              </div>
              <%!-- Said rather than implied. The composer's form carries live hooks
                    and a `chat_send` submit that would crash this page, so the
                    preview is the transcript; and the skins' translucency and
                    shadow rules describe a panel over the homepage's shader, which
                    a settings page does not have. Both are real gaps, and a
                    preview that quietly omitted them would be the kind of promise
                    this app keeps getting wrong. --%>
              <p class="text-xs leading-5 text-base-content/55">
                The transcript only — the message box and the panel's own edges are shown on
                the homepage.
              </p>
            </section>
          </div>

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
                  style={"background:#{t.swatch.bg}"}
                >
                  <span class="text-xs font-bold leading-none" style={"color:#{t.swatch.fg}"}>
                    $ ls
                  </span>
                  <span class="h-1.5 w-5 rounded-full" style={"background:#{t.swatch.accent}"}></span>
                </span>
                <span class="min-w-0">
                  <span class="block text-sm font-semibold">{t.label}</span>
                  <span class="block font-mono text-xs text-base-content/55">{t.key}</span>
                </span>
                <%!-- The one thing that tells the operator this row is not theirs.
                      Marked rather than moved: the agent's theme is selectable
                      exactly like any other, and the badge is the whole
                      difference. --%>
                <span
                  :if={agent_slot?(t, @agent_theme)}
                  class="ml-auto shrink-0 rounded border-2 border-primary/60 px-1.5 py-0.5 font-mono text-[0.6rem] font-bold uppercase tracking-wide text-primary"
                >
                  Agent
                </span>
              </button>
            </div>

            <%!-- Only when there is one. An explanation of a row that isn't there
                  is a promise about a feature the operator hasn't met. --%>
            <p :if={@agent_theme} class="text-xs leading-6 text-base-content/60">
              <span class="font-semibold">{@agent_theme.label}</span>
              is the agent's own slot — it painted that, it is the only theme it can write,
              and its own reset clears it. Select it, keep it, or ignore it; your colours
              below are untouched either way.
            </p>

            <%!-- The custom slot. Creating one means COPYING a preset, which is the
                  design rather than a convenience: a copy is always a complete
                  22-colour palette, so a custom theme can never be the half-applied
                  thing where the background is yours and `ls` is xterm's. It also
                  makes the common case one edit.

                  Industrial is not offered as a starting point because it has no
                  fixed colours to copy — it is resolved from the app's tokens so it
                  can follow the light/dark switch. --%>
            <div class="space-y-3 border-t-2 border-base-content/15 pt-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h3 class="ic-eyebrow">Your own</h3>
                <div :if={@custom_theme} class="flex gap-2">
                  <button
                    type="button"
                    phx-click="edit_custom_theme"
                    class="rounded border-2 border-base-content/25 px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide transition hover:border-primary hover:text-primary"
                  >
                    Edit colours
                  </button>
                  <button
                    type="button"
                    phx-click="delete_custom_theme"
                    class="rounded border-2 border-error/50 px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide text-error transition hover:bg-error/10"
                  >
                    Delete
                  </button>
                </div>
              </div>

              <%!-- The spectrum. One number produces all 21 colours, which is what
                    keeps a custom theme from ever being half-applied — and it makes
                    the first move a drag rather than a form. The hue tints the
                    surfaces fully; the program colours are pulled only slightly
                    toward it, so red stays red at every position. --%>
              <form phx-change="generate_custom_theme" class="space-y-1.5">
                <div class="flex items-baseline justify-between gap-2">
                  <label for="custom-theme-hue" class="ic-eyebrow">Spectrum</label>
                  <span class="font-mono text-[0.62rem] uppercase tracking-wide text-base-content/50">
                    {@custom_hue}°
                  </span>
                </div>
                <input
                  id="custom-theme-hue"
                  type="range"
                  name="hue"
                  min={Enum.min(TerminalTheme.hue_range())}
                  max={Enum.max(TerminalTheme.hue_range())}
                  value={@custom_hue}
                  data-hue-slider
                  class="ic-hue-slider"
                />
                <p class="text-xs leading-5 text-base-content/60">
                  <span :if={is_nil(@custom_theme)}>
                    Drag to build a theme — every colour is generated, so program output
                    stays themed.
                  </span>
                  <span :if={@custom_theme}>
                    Moving this rebuilds every colour. Edit the swatches below to change
                    one at a time.
                  </span>
                </p>
              </form>

              <%!-- One form for the whole palette: every input is named for its
                    field, so the params are the palette and there is no per-field
                    event to keep in step with the field list. Saved on every change
                    — the terminal restyles while the picker is still open. --%>
              <%!-- `phx-submit` mirrors `phx-change` and is not decorative: the
                    Name field is a text input, so Enter would submit this form
                    NATIVELY, reload /appearance, and take the half-built palette
                    with it. Same defect found in Studio -> Voice in the 08-15
                    packaged build (DMG-review-8-15, finding 3). --%>
              <form
                :if={@custom_draft}
                id="custom-theme-editor"
                phx-change="save_custom_theme"
                phx-submit="save_custom_theme"
                class="space-y-4"
              >
                <div class="space-y-1">
                  <label for="custom-theme-name" class="ic-eyebrow block">Name</label>
                  <input
                    id="custom-theme-name"
                    type="text"
                    name="name"
                    value={@custom_name}
                    maxlength="40"
                    class="w-full rounded border-2 border-base-content/25 bg-base-100 px-3 py-1.5 text-sm font-semibold focus:border-primary focus:outline-none"
                  />
                </div>

                <p :if={@custom_error} role="alert" class="text-sm font-semibold text-error">
                  {@custom_error}
                </p>

                <%!-- Three groups rather than 21 swatches in one grid, because they
                      answer different questions: what the terminal IS, what programs
                      draw with, and what they use for emphasis. Every colour is
                      visible — the previous version hid sixteen of them behind a
                      collapsed section, which is most of the palette. --%>
                <div
                  :for={{title, blurb, fields} <- TerminalTheme.field_groups()}
                  data-color-group={title}
                  class="space-y-2"
                >
                  <div>
                    <h4 class="ic-eyebrow">{title}</h4>
                    <p class="text-xs leading-5 text-base-content/55">{blurb}</p>
                  </div>
                  <div class="grid gap-2 sm:grid-cols-2">
                    <.color_row
                      :for={{field, label} <- fields}
                      field={field}
                      label={label}
                      value={@custom_draft[field]}
                    />
                  </div>
                </div>

                <div class="flex items-center justify-between gap-3">
                  <p class="text-xs leading-5 text-base-content/55">
                    Saved as you go, and applied to every open terminal. A custom theme keeps
                    its colours when you switch the app between light and dark — only Industrial
                    follows that.
                  </p>
                  <button
                    type="button"
                    phx-click="close_custom_theme"
                    class="shrink-0 rounded border-2 border-base-content/25 px-3 py-1.5 text-sm font-semibold transition hover:border-primary hover:text-primary"
                  >
                    Done
                  </button>
                </div>
              </form>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # One palette field: a native colour swatch, its label, and the hex it resolves
  # to.
  #
  # The swatch is the only input — the hex is shown, not typed. A second text input
  # sharing the field's `name` would put two values on the wire for one field, and
  # "pick a colour" is what was asked for; a hex field is a power-user affordance
  # that can be added later without changing the store.
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp color_row(assigns) do
    ~H"""
    <label class="flex items-center gap-2 rounded border-2 border-base-content/20 px-2 py-1.5">
      <input
        type="color"
        name={@field}
        value={@value}
        data-color-field={@field}
        aria-label={@label}
        class="size-7 shrink-0 cursor-pointer rounded-sm border-0 bg-transparent p-0"
      />
      <span class="min-w-0 flex-1 truncate text-sm">{@label}</span>
      <span class="shrink-0 font-mono text-[0.62rem] uppercase text-base-content/55">
        {@value}
      </span>
    </label>
    """
  end

  # Whether this picker row is the agent's slot rather than a preset or the
  # operator's own. `nil` means the agent has never painted, so no row is.
  defp agent_slot?(_theme, nil), do: false
  defp agent_slot?(theme, agent), do: theme.key == agent.key

  defp assign_terminal_themes(socket) do
    socket
    |> assign(:terminal_themes, TerminalTheme.themes())
    |> assign(:custom_theme, TerminalTheme.custom())
    # Read here rather than derived from `terminal_themes` — the agent may paint
    # while this page is open, and the row has to be able to say whose it is
    # without the picker list having to carry that fact.
    |> assign(:agent_theme, TerminalTheme.agent())
    |> assign_new(:custom_draft, fn -> nil end)
    |> assign_new(:custom_name, fn -> TerminalTheme.custom_name() end)
    |> assign_new(:custom_hue, fn -> TerminalTheme.custom_hue() end)
    |> assign_new(:custom_error, fn -> nil end)
  end

  defp open_draft(socket, theme) do
    socket
    |> assign(:custom_draft, theme.palette)
    |> assign(:custom_name, theme.label)
    |> assign(:custom_hue, TerminalTheme.custom_hue())
    |> assign(:custom_error, nil)
  end

  # Persist, refresh the picker, and push the palette at the browser so every open
  # terminal restyles without a reload. The push is what makes this live; the
  # Settings write is what makes it survive a restart.
  defp save_draft(socket, draft, hue \\ nil) do
    case TerminalTheme.set_custom(socket.assigns.custom_name, draft, hue) do
      {:ok, theme} ->
        socket
        |> assign(:custom_draft, draft)
        |> assign(:custom_error, nil)
        |> assign_terminal_themes()
        |> push_event("bc-term-custom", %{palette: theme.palette})

      {:error, reason} ->
        socket
        |> assign(:custom_draft, draft)
        |> assign(:custom_error, custom_error_text(reason))
    end
  end

  defp custom_error_text(:invalid_name), do: "Give the theme a name (up to 40 characters)."
  defp custom_error_text(:invalid_colors), do: "That is not a valid #rrggbb colour."

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
        data-assigned={assigned_badge(@assigned)}
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
    # Recomputed with the rest rather than only at mount: writing a workspace
    # shader that samples the image should make it offerable without a restart.
    |> assign(:overlays, Appearance.image_shader_options())
    |> assign(:pool_full, Appearance.pool_full?())
  end

  defp overlay_error(:not_image_reactive),
    do: "That design ignores the image — pick one that reads it, or None."

  defp overlay_error(:empty_slot), do: "That image slot is empty."
  defp overlay_error(_reason), do: "That overlay could not be applied."

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

  defp short_label(:home), do: "Home"
  defp short_label(:terminal), do: "Term"

  defp upload_error_to_string(:too_large), do: "That image is larger than 8 MB."
  defp upload_error_to_string(:too_many_files), do: "Choose a single image."
  defp upload_error_to_string(:not_accepted), do: "Use a PNG, JPG, WEBP, or GIF image."
  defp upload_error_to_string(_), do: "That image couldn't be uploaded."

  defp theme_btn,
    do:
      "inline-flex items-center gap-2 rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:border-primary hover:text-primary"
end
