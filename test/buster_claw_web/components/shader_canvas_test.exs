defmodule BusterClawWeb.ShaderCanvasTest do
  # The one component the homepage, the terminal and a split all render their
  # background through. Its attributes ARE the contract with the SmokeBackground
  # hook: a missing one is a setting that silently stops applying, which no
  # Elixir test would otherwise notice (render_hook never touches JS).
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias BusterClawWeb.ShaderCanvas

  defp render(bg, opts \\ []) do
    assigns = %{
      bg: bg,
      prefix: Keyword.get(opts, :prefix, "home"),
      class: Keyword.get(opts, :class, "ic-shader-fill"),
      render?: Keyword.get(opts, :render?, true)
    }

    rendered_to_string(
      ShaderCanvas.shader_canvas(%{
        bg: assigns.bg,
        prefix: assigns.prefix,
        class: assigns.class,
        render?: assigns.render?
      })
    )
  end

  defp shader_bg(overrides \\ %{}) do
    Map.merge(
      %{
        kind: :shader,
        mode: "waves",
        shader: "waves",
        source_url: nil,
        image_url: nil,
        slot: nil,
        custom: false,
        colors: ["#000000", "#ff4d1c", "#ffffff"],
        custom_shader: false
      },
      overrides
    )
  end

  test "a plain shader renders the canvas and carries no image" do
    html = render(shader_bg())

    assert html =~ ~s|phx-hook="SmokeBackground"|
    assert html =~ ~s|data-shader="waves"|
    assert html =~ "<canvas"
    refute html =~ "data-image-url"
  end

  test "an image-reactive shader carries the image url the hook samples" do
    html =
      render(
        shader_bg(%{
          kind: :image_shader,
          mode: "veil",
          shader: "veil",
          image_url: "/appearance/image/2?v=9",
          slot: 2
        })
      )

    # This attribute IS the feature. Without it the hook binds nothing, veil's
    # has_img() returns 0, and the background degrades to a plain pattern while
    # the picker still says "image + veil".
    assert html =~ ~s|data-image-url="/appearance/image/2?v=9"|
    assert html =~ ~s|data-shader="veil"|
  end

  test "a plain image and an off background render nothing here" do
    # An image with no overlay is painted by CSS on the surface, not by a canvas.
    assert render(shader_bg(%{kind: :image, shader: nil, image_url: "/x"})) |> String.trim() == ""
    assert render(shader_bg(%{kind: :none, shader: nil})) |> String.trim() == ""
  end

  test "render? gates it for an embedded pane" do
    assert render(shader_bg(), render?: false) |> String.trim() == ""
  end

  describe "the remount key" do
    # phx-update="ignore" means LiveView never patches inside this div, so the
    # ONLY way a changed background reaches the hook is a changed id. Anything the
    # hook reads at mount must therefore be in the key.
    test "changing the image remounts the hook" do
      one = shader_bg(%{kind: :image_shader, shader: "veil", image_url: "/appearance/image/1"})
      two = shader_bg(%{kind: :image_shader, shader: "veil", image_url: "/appearance/image/2"})

      assert dom_id(render(one)) != dom_id(render(two))
    end

    test "changing the shader, the palette, or the custom flag remounts it" do
      base = shader_bg()

      assert dom_id(render(base)) != dom_id(render(shader_bg(%{shader: "mandel"})))
      assert dom_id(render(base)) != dom_id(render(shader_bg(%{custom: true})))

      assert dom_id(render(base)) !=
               dom_id(render(shader_bg(%{colors: ["#111111", "#222222", "#333333"]})))
    end

    test "the same background twice is the same id — it must NOT churn" do
      assert dom_id(render(shader_bg())) == dom_id(render(shader_bg()))
    end

    test "the prefix keeps two surfaces' canvases distinct on one page" do
      # A split renders its own canvas while a terminal pane may render one too;
      # duplicate DOM ids would make LiveView patch the wrong element.
      assert dom_id(render(shader_bg(), prefix: "split")) !=
               dom_id(render(shader_bg(), prefix: "terminal"))
    end
  end

  defp dom_id(html) do
    [_, id] = Regex.run(~r/id="([^"]+)"/, html)
    id
  end
end
