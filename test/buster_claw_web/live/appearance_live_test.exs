defmodule BusterClawWeb.AppearanceLiveTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Appearance
  alias BusterClaw.ChatSkin
  alias BusterClaw.ChatTextSize
  alias BusterClaw.TerminalTheme

  setup do
    root = Path.join(System.tmp_dir!(), "bc_appearance_lv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_custom_shader(root, name) do
    dir = Path.join(root, "shaders")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, name <> ".wgsl"),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0); }\n"
    )
  end

  # Same shape, but the body calls the image API — which is what makes
  # `Shaders.samples_image?/1` true and so what makes the overlay picker offer it.
  defp write_image_shader(root, name) do
    dir = Path.join(root, "shaders")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, name <> ".wgsl"),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return img(in.uv); }\n"
    )
  end

  defp add_image do
    src = Path.join(System.tmp_dir!(), "bc_lv_#{System.unique_integer([:positive])}.png")
    File.write!(src, "img-bytes")
    {:ok, slot} = Appearance.put_image(src, "a.png")
    slot
  end

  # --- the page's shape ----------------------------------------------------

  test "renders both surface panels and a single shared catalog", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    assert has_element?(view, "#backgrounds")
    assert has_element?(view, "#surface-home")
    assert has_element?(view, "#surface-terminal")

    # One row per option, and each built-in shader appears exactly once — the
    # whole point of the redesign is that the catalog isn't duplicated per surface.
    for shader <- Appearance.builtin_shaders() do
      assert view |> element("[data-bg-option='#{shader}']") |> has_element?()
    end

    assert has_element?(view, "[data-bg-option='off']")
    assert has_element?(view, "#background-upload-form")
  end

  test "every filled option offers both surface buttons; an empty slot offers none",
       %{conn: conn} do
    slot = add_image()
    {:ok, view, _html} = live(conn, "/appearance")

    for opt <- ["off", "smoke", "image:#{slot}"], surface <- ["home", "terminal"] do
      assert has_element?(
               view,
               "[data-bg-option='#{opt}'] button[phx-value-surface='#{surface}']"
             )
    end

    # Slot 8 is empty — a placeholder, not something you can send anywhere.
    refute has_element?(view, "[data-bg-option='image:8'] button[phx-value-surface='home']")
  end

  test "shader options carry no thumbnail; images do", %{conn: conn} do
    slot = add_image()
    {:ok, view, _html} = live(conn, "/appearance")

    # The thumbnail box is the aspect-video preview. A shader has none — the only
    # honest preview of a shader is the shader, running in the surface panels.
    refute has_element?(view, "[data-bg-option='smoke'] .aspect-video")
    refute has_element?(view, "[data-bg-option='off'] .aspect-video")
    assert has_element?(view, "[data-bg-option='image:#{slot}'] .aspect-video")
  end

  test "the catalog offers workspace shaders but never shaderfaces", %{conn: conn, root: root} do
    write_custom_shader(root, "aurora")
    write_custom_shader(root, "face-luke")
    write_custom_shader(root, "viking-face")

    {:ok, view, _html} = live(conn, "/appearance")

    assert has_element?(view, "[data-bg-option='aurora']")
    refute has_element?(view, "[data-bg-option='face-luke']")
    refute has_element?(view, "[data-bg-option='viking-face']")
  end

  # --- assigning ------------------------------------------------------------

  test "assigning an option touches that surface only", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "terminal", "option" => "waves"})

    assert Appearance.background(:terminal).shader == "waves"
    assert Appearance.background(:home).mode == "smoke"
  end

  test "the same image can back both surfaces", %{conn: conn} do
    slot = add_image()
    {:ok, view, _html} = live(conn, "/appearance")

    for surface <- ["home", "terminal"] do
      render_click(view, "assign_background", %{"surface" => surface, "option" => "image:#{slot}"})
    end

    assert Appearance.background(:home).slot == slot
    assert Appearance.background(:terminal).slot == slot
  end

  test "a row button assigns through the same server event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    view
    |> element("[data-bg-option='mandel'] button[phx-value-surface='home']")
    |> render_click()

    assert Appearance.background(:home).shader == "mandel"
  end

  test "a surface running an option shows a live preview of it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "home", "option" => "waves"})

    assert has_element?(
             view,
             "#surface-home [phx-hook='ShaderPreview'][data-shader='waves'] canvas"
           )
  end

  test "an image-backed surface previews the image, not a canvas", %{conn: conn} do
    slot = add_image()
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{
      "surface" => "terminal",
      "option" => "image:#{slot}"
    })

    refute has_element?(view, "#surface-terminal [phx-hook='ShaderPreview']")
    assert render(view) =~ Appearance.image_url(slot)
  end

  test "an off surface renders neither a canvas nor an image", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "home", "option" => "off"})

    refute has_element?(view, "#surface-home [phx-hook='ShaderPreview']")
    assert Appearance.background(:home).kind == :none
  end

  # --- refusals ------------------------------------------------------------

  test "a crafted event carrying a shaderface leaves the surface unchanged", %{
    conn: conn,
    root: root
  } do
    write_custom_shader(root, "face-luke")
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "home", "option" => "face-luke"})

    assert Appearance.home_background_state().mode == "smoke"
  end

  test "a crafted event naming an unknown surface is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "elsewhere", "option" => "waves"})

    assert Appearance.background(:home).mode == "smoke"
    assert Appearance.background(:terminal).kind == :none
  end

  test "assigning an empty slot is refused without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    html = render_click(view, "assign_background", %{"surface" => "home", "option" => "image:5"})

    assert html =~ "That slot is empty."
    assert Appearance.background(:home).mode == "smoke"
  end

  # --- the pool ------------------------------------------------------------

  test "removing an image degrades the surfaces using it", %{conn: conn} do
    slot = add_image()
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{
      "surface" => "terminal",
      "option" => "image:#{slot}"
    })

    assert Appearance.background(:terminal).kind == :image

    view
    |> element("[data-bg-option='image:#{slot}'] button[phx-value-slot='#{slot}']")
    |> render_click()

    assert Appearance.background(:terminal).kind == :none
    assert Appearance.image_url(slot) == nil
  end

  test "a crafted remove_image slot value is a no-op, not a crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    assert render_click(view, "remove_image", %{"slot" => "not-a-number"})
    assert Process.alive?(view.pid)
  end

  # --- per-surface palette -------------------------------------------------

  test "the palette toggle is per surface", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "home", "option" => "waves"})
    render_click(view, "assign_background", %{"surface" => "terminal", "option" => "waves"})

    view
    |> element("#surface-home input[type='checkbox'][phx-value-surface='home']")
    |> render_click()

    assert Appearance.custom?(:home)
    refute Appearance.custom?(:terminal)
  end

  test "color inputs are namespaced per surface so each preview reads its own", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "terminal", "option" => "waves"})
    render_click(view, "toggle_custom", %{"surface" => "terminal"})

    assert has_element?(view, "#terminal-color-1")
    assert has_element?(view, "#surface-terminal [data-color-prefix='terminal-color-']")
  end

  test "setting colors writes only that surface's palette", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "assign_background", %{"surface" => "terminal", "option" => "waves"})
    render_click(view, "toggle_custom", %{"surface" => "terminal"})

    view
    |> element("#surface-terminal form[phx-change='set_colors']")
    |> render_change(%{
      "surface" => "terminal",
      "c1" => "#112233",
      "c2" => "#445566",
      "c3" => "#778899"
    })

    assert Appearance.colors(:terminal) == ["#112233", "#445566", "#778899"]
    assert Appearance.colors(:home) == ["#0e0e0e", "#ff4d1c", "#f4f1ea"]
  end

  describe "the custom terminal theme" do
    # Dragging the spectrum is now the only way to create one, which is also what
    # makes the palette complete before a single swatch is touched.
    defp drag_spectrum(view, hue \\ 200) do
      view
      |> element(~s(form[phx-change="generate_custom_theme"]))
      |> render_change(%{"hue" => to_string(hue)})
    end

    defp palette_params(overrides) do
      Map.merge(TerminalTheme.generate(200), overrides)
    end

    test "offers the three presets and a spectrum, not a list of copies",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      for key <- TerminalTheme.preset_keys() do
        assert has_element?(view, ~s([data-term-theme="#{key}"]))
      end

      # The six removed presets are gone from the picker as well as the catalog.
      for gone <- ~w(dracula solarized gruvbox tokyo-night light matrix) do
        refute has_element?(view, ~s([data-term-theme="#{gone}"]))
      end

      # The spectrum replaced "start from a preset" (08-09).
      assert has_element?(view, "[data-hue-slider]")
      refute has_element?(view, "[data-start-from]")
    end

    test "dragging the spectrum opens a complete editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      drag_spectrum(view)

      assert has_element?(view, "#custom-theme-editor")

      # Every one of the 21 fields, visible — no collapsed section hiding most of
      # the palette, and complete so a custom theme can never be half-applied.
      for {field, _label} <- TerminalTheme.fields() do
        assert has_element?(view, ~s(#custom-theme-editor [data-color-field="#{field}"])),
               "the editor has no input for #{field}"
      end
    end

    test "the swatches are grouped, and the groups cover the palette", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")
      drag_spectrum(view)

      for {title, _blurb, _fields} <- TerminalTheme.field_groups() do
        assert has_element?(view, ~s(#custom-theme-editor [data-color-group="#{title}"]))
      end
    end

    test "dragging the spectrum saves a whole palette and remembers where it was",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      drag_spectrum(view, 300)

      theme = TerminalTheme.custom()
      assert map_size(theme.palette) == length(TerminalTheme.fields())
      assert theme.palette == TerminalTheme.generate(300)

      # The slider has to come back where it was left, or it reads as a control
      # that forgot.
      assert TerminalTheme.custom_hue() == 300
      assert render(view) =~ "300°"
    end

    test "a nonsense hue is ignored rather than crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element(~s(form[phx-change="generate_custom_theme"]))
      |> render_change(%{"hue" => "banana"})

      assert TerminalTheme.custom() == nil
    end

    test "changing a colour saves it and pushes it at the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")
      drag_spectrum(view)

      view
      |> element("#custom-theme-editor")
      |> render_change(palette_params(%{"background" => "#010203", "name" => "Mine"}))

      # Persisted, so it survives a restart...
      assert TerminalTheme.palette("custom")["background"] == "#010203"
      assert TerminalTheme.custom_name() == "Mine"

      # ...and pushed, which is what restyles open terminals with no reload. The
      # <meta> the layout renders cannot change without one.
      assert_push_event(view, "bc-term-custom", %{palette: %{"background" => "#010203"}})
    end

    test "a saved theme joins the picker and can be re-opened", %{conn: conn} do
      TerminalTheme.set_custom("Mine", palette_params(%{"background" => "#010203"}))

      {:ok, view, html} = live(conn, "/appearance")

      assert has_element?(view, ~s([data-term-theme="custom"]))
      assert html =~ "Mine"

      view |> element(~s(button[phx-click="edit_custom_theme"])) |> render_click()
      assert has_element?(view, "#custom-theme-editor")
    end

    test "a bad colour is refused with a message, and the saved palette is untouched",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")
      drag_spectrum(view, 200)
      good = TerminalTheme.palette("custom")

      html =
        view
        |> element("#custom-theme-editor")
        |> render_change(palette_params(%{"red" => "not-a-colour", "name" => "Mine"}))

      assert html =~ "not a valid #rrggbb colour"
      # Refused whole: the palette on disk is the last one that validated, not a
      # half-applied mixture of it and the bad edit.
      assert TerminalTheme.palette("custom") == good
    end

    test "an empty name is refused rather than saved blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")
      drag_spectrum(view)
      before = TerminalTheme.custom_name()

      html =
        view
        |> element("#custom-theme-editor")
        |> render_change(palette_params(%{"name" => "   "}))

      assert html =~ "Give the theme a name"
      assert TerminalTheme.custom_name() == before
    end

    test "deleting removes it from the picker and tells the browser", %{conn: conn} do
      TerminalTheme.set_custom("Mine", palette_params(%{}))
      {:ok, view, _html} = live(conn, "/appearance")

      view |> element(~s(button[phx-click="delete_custom_theme"])) |> render_click()

      assert TerminalTheme.custom() == nil
      refute has_element?(view, ~s([data-term-theme="custom"]))
      assert_push_event(view, "bc-term-custom", %{palette: nil})
      # The spectrum is always there — it is the way back in.
      assert has_element?(view, "[data-hue-slider]")
    end
  end

  describe "the agent's theme slot" do
    defp paint_agent(overrides \\ %{}) do
      {:ok, theme} =
        TerminalTheme.set_agent("Sodium", Map.merge(%{"cursor" => "#ff9d2f"}, overrides))

      theme
    end

    test "is absent from the picker until the agent has painted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      refute has_element?(view, ~s([data-term-theme="#{TerminalTheme.agent_key()}"]))
      # And no explanation of a row that isn't there.
      refute render(view) =~ "the only theme it can write"
    end

    test "appears in the picker with its own swatch once painted", %{conn: conn} do
      theme = paint_agent(%{"background" => "#100c06"})

      {:ok, view, html} = live(conn, "/appearance")

      assert has_element?(view, ~s([data-term-theme="#{TerminalTheme.agent_key()}"]))
      assert html =~ "Sodium"
      # The swatch is the agent's palette, not a stand-in.
      assert html =~ "background:#{theme.palette["background"]}"
    end

    test "the row says it is the agent's, not the operator's", %{conn: conn} do
      TerminalTheme.set_custom("Mine", TerminalTheme.generate(200))
      paint_agent()

      {:ok, view, html} = live(conn, "/appearance")

      # The badge is the whole difference between this row and a preset — without
      # it the operator cannot tell a theme the model painted from one they made.
      assert view
             |> element(~s([data-term-theme="#{TerminalTheme.agent_key()}"]))
             |> render() =~ "Agent"

      refute view
             |> element(~s([data-term-theme="#{TerminalTheme.custom_key()}"]))
             |> render() =~ "Agent"

      assert html =~ "the only theme it can write"
    end

    test "is selectable exactly like any other theme", %{conn: conn} do
      TerminalTheme.set_custom("Mine", TerminalTheme.generate(200))
      paint_agent()

      {:ok, view, _html} = live(conn, "/appearance")

      # Same dispatch, same data attribute — the badge marks the row, it does not
      # make it a different kind of control.
      for key <- TerminalTheme.keys() do
        assert has_element?(
                 view,
                 ~s(button[phx-click][data-term-theme="#{key}"])
               )
      end
    end

    test "carries no editor and no delete button", %{conn: conn} do
      paint_agent()

      {:ok, view, _html} = live(conn, "/appearance")

      # Deliberate: `terminal_theme_reset` clears the agent slot, and this page is
      # not the surface that owns it. An Edit here would also be an operator
      # writing the model's theme, which nothing else in this feature allows.
      refute has_element?(view, ~s(button[phx-click="edit_agent_theme"]))
      refute has_element?(view, ~s(button[phx-click="delete_agent_theme"]))
    end

    test "the operator's own slot is untouched by a paint", %{conn: conn} do
      TerminalTheme.set_custom("Mine", TerminalTheme.generate(200))
      mine = TerminalTheme.custom()

      paint_agent(%{"background" => "#100c06"})

      {:ok, view, html} = live(conn, "/appearance")

      assert TerminalTheme.custom() == mine
      assert html =~ "Mine"
      # Both dynamic slots render, side by side, and the operator's keeps its
      # Edit/Delete controls.
      assert has_element?(view, ~s([data-term-theme="#{TerminalTheme.custom_key()}"]))
      assert has_element?(view, ~s(button[phx-click="delete_custom_theme"]))
    end

    test "deleting the operator's theme leaves the agent's in the picker", %{conn: conn} do
      TerminalTheme.set_custom("Mine", TerminalTheme.generate(200))
      paint_agent()

      {:ok, view, _html} = live(conn, "/appearance")

      view |> element(~s(button[phx-click="delete_custom_theme"])) |> render_click()

      # The re-render walks both dynamic slots; losing one must not lose the other.
      refute has_element?(view, ~s([data-term-theme="#{TerminalTheme.custom_key()}"]))
      assert has_element?(view, ~s([data-term-theme="#{TerminalTheme.agent_key()}"]))
    end
  end

  describe "the chat theme picker" do
    test "offers every skin, with the one in force selected", %{conn: conn} do
      {:ok, view, html} = live(conn, "/appearance")

      # Derived from the catalog, not restated: a skin added to ChatSkin and
      # forgotten here would be a skin nobody can choose.
      for skin <- ChatSkin.skins() do
        assert html =~ skin.label
        assert has_element?(view, ~s(#chat-skin-select option[value="#{skin.key}"]))
      end

      assert has_element?(
               view,
               ~s(#chat-skin-select option[value="#{ChatSkin.default()}"][selected])
             )
    end

    test "picking a skin persists it with no Save button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("form[phx-change='set_chat_skin']")
      |> render_change(%{"skin" => "minimal"})

      assert ChatSkin.get() == "minimal"
      refute has_element?(view, "form[phx-change='set_chat_skin'] button[type='submit']")
    end

    test "the preview restyles in the same round-trip", %{conn: conn} do
      {:ok, view, html} = live(conn, "/appearance")

      # The preview is the whole answer to "see it immediately" — the operator is
      # on this page and cannot see the homepage.
      assert html =~ ~s(data-chat-skin-preview)
      assert html =~ ~s(data-chat-skin="#{ChatSkin.default()}")

      html =
        view
        |> element("form[phx-change='set_chat_skin']")
        |> render_change(%{"skin" => "slack"})

      assert html =~ ~s(data-chat-skin="slack")
      # And the blurb follows the selection, so the description never describes
      # the skin you just left.
      assert html =~ ChatSkin.label("slack")
    end

    test "the preview renders the real bubbles, every role", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      # Through the same private chat_bubble/1 the live chat uses. A second copy
      # of the bubble markup would drift, and this is the surface where a drift
      # would be least visible.
      for role <- ~w(user assistant tool meta) do
        assert has_element?(view, ~s([data-chat-skin-preview] [data-chat-role="#{role}"]))
      end
    end

    test "the preview says what it is not showing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/appearance")

      # The composer cannot mount here (live hooks, a chat_send submit) and the
      # panel-chrome rules describe a panel over the homepage's shader. Both are
      # real gaps, and an unlabelled preview would be a quiet promise.
      assert html =~ "The transcript only"
      refute html =~ ~s(phx-submit="chat_send")
    end

    test "sits in the left column under Theme, not below the whole page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/appearance")

      # Placement, asserted by document order: the left grid cell stacks Theme
      # then Chat theme, so the chat panel comes BEFORE the tall terminal palette
      # that fills the right cell. It used to come after everything, which left an
      # empty half-column under Theme.
      #
      # This is also a guard against the obvious "fix" — making Chat theme a third
      # child of the two-column grid. Auto-placement would put it in column 1 row
      # 2, below the terminal column's baseline, and the gap would come back with
      # the markup looking correct.
      assert :binary.match(html, "chat-skin-heading") < :binary.match(html, "Terminal theme")
    end

    test "offers every text size with its percentage", %{conn: conn} do
      {:ok, view, html} = live(conn, "/appearance")

      for size <- ChatTextSize.sizes() do
        assert has_element?(view, ~s(#chat-text-size-select option[value="#{size.key}"]))
        # The percentage comes from the module's own scale, so the promise on
        # screen and the multiplier in the CSS are one number.
        assert html =~ "#{size.label} · #{ChatTextSize.percent(size.key)}%"
      end
    end

    test "picking a size persists it and shows it in the preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      html =
        view
        |> element("form[phx-change='set_chat_text_size']")
        |> render_change(%{"size" => "larger"})

      assert ChatTextSize.get() == "larger"
      assert html =~ ~s(data-chat-text-size="larger")
    end

    test "size and skin are independent controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      view |> element("form[phx-change='set_chat_skin']") |> render_change(%{"skin" => "minimal"})

      html =
        view
        |> element("form[phx-change='set_chat_text_size']")
        |> render_change(%{"size" => "largest"})

      # Bigger text must not cost you the look you picked — the reason these are
      # two settings and not one list of twelve.
      assert html =~ ~s(data-chat-skin="minimal")
      assert html =~ ~s(data-chat-text-size="largest")
      assert ChatSkin.get() == "minimal"
    end

    test "a size the dropdown could not have offered is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("form[phx-change='set_chat_text_size']")
      |> render_change(%{"size" => "gigantic"})

      assert ChatTextSize.get() == ChatTextSize.default()
    end

    test "a skin the dropdown could not have offered is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("form[phx-change='set_chat_skin']")
      |> render_change(%{"skin" => "vaporwave"})

      assert ChatSkin.get() == ChatSkin.default()
    end
  end

  # --- the shader overlay (IMAGE_SHADER_ROADMAP Phase 3) --------------------

  describe "the shader overlay picker" do
    test "appears only once a surface is showing an image", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/appearance")
      # Home defaults to the smoke shader, so there is nothing to overlay onto.
      refute has_element?(view, "#home-overlay")

      slot = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}")
      {:ok, view, _html} = live(conn, "/appearance")

      assert has_element?(view, "#home-overlay")
      # ...and only for the surface that is showing one.
      refute has_element?(view, "#terminal-overlay")
    end

    test "choosing one puts the shader over the image", %{conn: conn} do
      slot = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}")
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("#surface-home form[phx-change='set_overlay']")
      |> render_change(%{"surface" => "home", "shader" => "veil"})

      assert %{kind: :image_shader, shader: "veil", slot: ^slot} = Appearance.background(:home)
    end

    # The bug this guards was found by opening the app, not by reading: adding an
    # overlay made the image tile stop saying it was in use, so the grid claimed
    # nothing was selected while the surface panel read "Image N + veil". The
    # unit test on catalog_key/1 cannot see this — only rendering the grid can.
    test "the image tile still reads as in use once an overlay is added", %{conn: conn} do
      slot = add_image()
      {:ok, _} = Appearance.set_background(:terminal, "image:#{slot}")
      {:ok, view, html} = live(conn, "/appearance")

      # Scoped to THIS tile via data-bg-option, not a substring over the page:
      # every tile carries a "Term" assign button, so `html =~ "Term"` would
      # pass with no badge rendered anywhere.
      badge = ~s([data-bg-option="image:#{slot}"] [data-assigned])

      assert has_element?(view, badge),
             "expected the plain image tile to badge before the overlay"

      assert html =~ "data-assigned"

      view
      |> element("#surface-terminal form[phx-change='set_overlay']")
      |> render_change(%{"surface" => "terminal", "shader" => "veil"})

      assert %{kind: :image_shader, slot: ^slot} = Appearance.background(:terminal)

      assert has_element?(view, badge),
             "the image tile lost its in-use badge once an overlay was applied — " <>
               "assigned_to/2 is matching on option_key/1 again instead of catalog_key/1"
    end

    test "choosing None takes it off again without losing the image", %{conn: conn} do
      slot = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}+veil")
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("#surface-home form[phx-change='set_overlay']")
      |> render_change(%{"surface" => "home", "shader" => ""})

      # Back to the plain image, still the SAME slot — removing an overlay must
      # not also clear which picture the surface was showing.
      assert %{kind: :image, slot: ^slot} = Appearance.background(:home)
    end

    test "the slot comes from the surface, not the form", %{conn: conn} do
      # The picker never carries a slot, so a crafted change cannot repoint a
      # surface at a different image while pretending to set an overlay.
      slot = add_image()
      other = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}")
      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("#surface-home form[phx-change='set_overlay']")
      |> render_change(%{"surface" => "home", "shader" => "veil", "slot" => to_string(other)})

      assert %{slot: ^slot} = Appearance.background(:home)
    end

    test "a shader that ignores the image is refused with a reason", %{conn: conn, root: root} do
      write_custom_shader(root, "plain")
      slot = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}")
      {:ok, view, _html} = live(conn, "/appearance")

      html =
        view
        |> element("#surface-home form[phx-change='set_overlay']")
        |> render_change(%{"surface" => "home", "shader" => "plain"})

      assert html =~ "ignores the image"
      # ...and the surface is left exactly as it was.
      assert %{kind: :image, slot: ^slot} = Appearance.background(:home)
    end

    test "the preview samples the same image the surface does", %{conn: conn} do
      # The lesson from the chat-skins preview: the one screen you open in order
      # to see the effect must not be the one screen that cannot show it.
      slot = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}+veil")
      {:ok, view, _html} = live(conn, "/appearance")

      url = Appearance.image_url(slot)

      assert has_element?(
               view,
               ~s|#surface-home [phx-hook="ShaderPreview"][data-image-url="#{url}"]|
             )
    end
  end

  # --- minting approval (AGENT_APPLIED_SHADERS_ROADMAP Phase 2) -------------

  describe "applying a workspace shader approves it for commands" do
    # Take the store's day-one backfill FIRST. It approves every shader present
    # the first time it is asked anything, so a shader written before this line
    # is already approved and a test asserting `shader_approved?` would pass
    # without the page doing a thing. Everything below writes its shader after
    # the stamp, which is the case the roadmap says still needs a click.
    setup do
      Appearance.approved_shaders()
      :ok
    end

    test "a catalog row's surface button mints approval", %{conn: conn, root: root} do
      write_custom_shader(root, "nebula")
      refute Appearance.shader_approved?("nebula")

      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("[data-bg-option='nebula'] button[phx-value-surface='home']")
      |> render_click()

      # Both halves matter: the operator got the background they clicked for, and
      # the click is what granted the capability. Approval is a side effect of the
      # choice, never a precondition for it.
      assert Appearance.background(:home).shader == "nebula"
      assert Appearance.shader_approved?("nebula")
    end

    # The path most likely to be written as scenery. An overlay is the roadmap's
    # own example, and a shader that mints as a bare name but not as
    # `image:<slot>+<name>` fails for exactly the case the operator will try
    # first — they watch it appear over their photo and the model still refuses.
    test "so does laying it over an image as an overlay", %{conn: conn, root: root} do
      write_image_shader(root, "nebula")
      slot = add_image()
      {:ok, _} = Appearance.set_background(:home, "image:#{slot}")
      refute Appearance.shader_approved?("nebula")

      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("#surface-home form[phx-change='set_overlay']")
      |> render_change(%{"surface" => "home", "shader" => "nebula"})

      assert %{kind: :image_shader, shader: "nebula"} = Appearance.background(:home)
      assert Appearance.shader_approved?("nebula")
    end

    # A built-in never needs approval — the command check accepts it outright —
    # so a record for one is noise in a store whose whole value is being
    # readable. The workspace file sharing the name is what makes this test
    # non-vacuous: a built-in SHADOWS a workspace file, so minting here would
    # store the hash of bytes that are not the bytes anything rendered.
    test "a built-in mints nothing, even shadowing a workspace file of the same name",
         %{conn: conn, root: root} do
      write_custom_shader(root, "veil")

      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("[data-bg-option='veil'] button[phx-value-surface='home']")
      |> render_click()

      assert Appearance.background(:home).shader == "veil"
      refute Map.has_key?(Appearance.approved_shaders(), "veil")
    end

    test "an image mints nothing", %{conn: conn, root: root} do
      # `nebula` is on disk and unapproved throughout: applying a picture must
      # not approve whatever shader happens to be sitting in the workspace.
      write_custom_shader(root, "nebula")
      slot = add_image()

      {:ok, view, _html} = live(conn, "/appearance")

      view
      |> element("[data-bg-option='image:#{slot}'] button[phx-value-surface='home']")
      |> render_click()

      assert Appearance.background(:home).kind == :image
      assert Appearance.approved_shaders() == %{}
    end

    # Roadmap risk VII.2: the operator clicks a shader to LOOK at it and silently
    # grants a standing capability. The page has to say so, and it has to say the
    # part about editing — otherwise an edited shader going back to refused reads
    # as the feature breaking.
    test "the picker discloses what applying a shader grants", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/appearance")

      assert html =~ "lets commands re-apply"
      assert html =~ "Edit the file"
    end
  end
end
