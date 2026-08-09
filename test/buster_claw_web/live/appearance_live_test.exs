defmodule BusterClawWeb.AppearanceLiveTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Appearance
  alias BusterClaw.ChatSkin
  alias BusterClaw.ChatTextSize

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
end
