defmodule BusterClawWeb.AppearanceLive do
  @moduledoc """
  Appearance settings (Settings → Appearance sub-tab).

  Backgrounds are **one catalog, shown once**: `off`, every shader (built-in and
  workspace), and the shared image pool. It is the left column and the picker
  for THE background — click a row and the Work Area, with every terminal in
  it, is on it. The middle column is the app's look: the theme buttons and the
  terminal palette. The right column holds the two surfaces that have a
  background — the Background panel, previewing what is running, and the Clock
  panel, a widget with a sky of its own and so its own picker over the same
  catalog (`Catalog.clock_picker/1`) — with the chat's look under them. The
  whole page fits one screen (`Layouts.app fit_viewport`); a column scrolls
  inside itself rather than the page scrolling.

  Redesigned 10-17. Until then there were three surfaces (the terminal had its
  own background) and every row carried a button per surface. A terminal is
  transparent over the app background now, so one click means one thing.

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

  import BusterClawWeb.Appearance.Catalog
  import BusterClawWeb.Appearance.Look
  import BusterClawWeb.Appearance.TerminalPalette

  # `phx-value-surface` arrives as a string. Resolve it through this table rather
  # than String.to_atom on user input.
  @surface_params %{"home" => :home, "widget" => :widget}

  @impl true
  def mount(_params, _session, socket) do
    # This page is where the app tells you a `.wgsl` file can go in `shaders/`,
    # so this is where that folder should come into existence.
    BusterClaw.Workspace.ensure_entry("shaders")

    {:ok,
     socket
     |> assign(:page_title, "Appearance")
     |> assign_terminal_themes()
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

  # One event, two senders: a catalog row (`phx-click`, surface=home) and the
  # Clock picker (`phx-change`, surface=widget). The form's `_target` rides
  # along unread.
  @impl true
  def handle_event("assign_background", %{"surface" => surface, "option" => option}, socket) do
    case surface_param(surface) do
      nil ->
        {:noreply, socket}

      s ->
        case Appearance.set_background(s, option) do
          {:ok, _key} ->
            mint_approval(option)

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
          mint_approval(key)
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
          |> put_flash(:info, "Image added — click it to use it.")

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
    <%!-- One screen, no page scroll (10-17): `fit_viewport` clamps the shell
          to the window, the grid row is `minmax(0,1fr)` so the three columns
          are exactly the room that is left, and each column scrolls inside
          itself if it must. Below `lg` the columns stack and the page scrolls
          as a page. --%>
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <section class="flex min-h-0 flex-1 flex-col gap-4">
        <BusterClawWeb.SettingsTabs.tabs active={:appearance} />

        <div
          id="backgrounds"
          class="grid min-h-0 flex-1 gap-4 overflow-y-auto lg:grid-cols-3 lg:grid-rows-[minmax(0,1fr)] lg:overflow-visible"
        >
          <%!-- Column 1: the catalog — images on top, shaders under. --%>
          <.backgrounds_catalog
            image_options={@image_options}
            shader_options={@shader_options}
            background={@backgrounds.home}
            upload={@uploads.background}
            pool_full={@pool_full}
          />

          <%!-- Column 2: the app's look — theme, then the terminal's. The
                `p-1 -m-1` keeps the panels' hard shadows inside the scroll
                box instead of clipped at its edge, and `shrink-0` on the
                children keeps a bounded flex column from squashing a panel's
                preview to nothing — it did, before the column scrolled. --%>
          <div class="-m-1 flex min-h-0 flex-col gap-4 overflow-y-auto p-1 [&>*]:shrink-0">
            <.theme_panel />
            <.terminal_theme_panel
              terminal_themes={@terminal_themes}
              agent_theme={@agent_theme}
              custom_theme={@custom_theme}
              custom_draft={@custom_draft}
              custom_name={@custom_name}
              custom_hue={@custom_hue}
              custom_error={@custom_error}
            />
          </div>

          <%!-- Column 3: what the two surfaces are running, and the chat. --%>
          <div class="-m-1 flex min-h-0 flex-col gap-4 overflow-y-auto p-1 [&>*]:shrink-0">
            <BusterClawWeb.SurfacePanel.surface_target
              surface={:home}
              bg={@backgrounds.home}
              overlays={@overlays}
            />
            <BusterClawWeb.SurfacePanel.surface_target
              surface={:widget}
              bg={@backgrounds.widget}
              overlays={@overlays}
            >
              <.clock_picker bg={@backgrounds.widget} options={@clock_options} />
            </BusterClawWeb.SurfacePanel.surface_target>
            <.chat_look_panel
              chat_skins={@chat_skins}
              chat_skin={@chat_skin}
              chat_text_sizes={@chat_text_sizes}
              chat_text_size={@chat_text_size}
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

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
    # The Clock's select: everything selectable, in catalog order. An empty slot
    # is a placeholder in the grid and nothing in a select.
    |> assign(:clock_options, Enum.filter(shader_options ++ image_options, & &1.filled))
    # Recomputed with the rest rather than only at mount: writing a workspace
    # shader that samples the image should make it offerable without a restart.
    |> assign(:overlays, Appearance.image_shader_options())
    |> assign(:pool_full, Appearance.pool_full?())
  end

  # A human just put this background on a surface, so if it carries one of their
  # own shaders, record that they have seen it — `background_set` may apply an
  # approved workspace shader from then on (AGENT_APPLIED_SHADERS_ROADMAP Phase
  # 2). This page is the ONLY place approval is minted, and that is the entire
  # security property: no command can tell a shader the model wrote from one the
  # operator wrote, so a human clicking it is the only signal there is to take.
  #
  # Called after `set_background/2` has already succeeded, never before. Approval
  # follows a choice that actually landed — a refused overlay must not leave the
  # operator having granted something for a background they never got.
  #
  # It also may not fail the click. `approve_shader/1` errors when the file will
  # not read, which cannot happen on this path (`set_background/2` just resolved
  # the same name), but if it ever did, flashing it would be exactly backwards:
  # the background IS applied, and the operator would be shown an error about a
  # capability they never asked for, over the change they did ask for.
  defp mint_approval(key) do
    case workspace_shader(key) do
      nil -> :ok
      name -> Appearance.approve_shader(name)
    end

    :ok
  end

  # The shader inside a background key, when it is one of the operator's own.
  #
  # Two forms, and the second is the one that gets forgotten: a bare name from a
  # catalog row, and `image:<slot>+<shader>` from the overlay picker. Both call
  # sites route through here rather than each doing their own extraction, because
  # a missed overlay is worse than a missing feature — the operator watches their
  # shader appear over their photo and the model still refuses to re-apply it,
  # which looks like the feature is broken rather than like a gate holding.
  #
  # `custom_shaders/0` is the filter rather than "not a built-in", so this is the
  # same list the catalog offers: a built-in (already applicable by command), a
  # shaderface, and a name that is no longer a file all drop out for free.
  # Approving a built-in would be inert, and inert rows in a security store are
  # how the store stops being readable.
  defp workspace_shader("off"), do: nil

  defp workspace_shader("image:" <> rest) do
    case String.split(rest, "+", parts: 2) do
      [_slot, shader] -> workspace_shader(shader)
      [_slot] -> nil
    end
  end

  defp workspace_shader(name) do
    if name in Appearance.custom_shaders(), do: name
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
end
