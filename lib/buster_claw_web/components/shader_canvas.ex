defmodule BusterClawWeb.ShaderCanvas do
  @moduledoc """
  The hook-owned WebGPU canvas that draws a surface's background.

  One component for the three surfaces that render one — the homepage
  (`StatusLive`), a standalone terminal (`TerminalLive`) and a split
  (`SplitLive`). All three had the same thirteen lines of `phx-hook` +
  `data-*` markup copied out, differing only in an id prefix and a class, and
  the copies had already drifted: the homepage keyed its `data-shader` off
  `bg.mode` while the other two used `bg.shader`.

  It exists because `IMAGE_SHADER_ROADMAP` Phase 3 had to add one attribute to
  all three, and both homepage files sit at their size cap — so the honest move
  was to remove the duplication rather than ratchet three caps for a copy-paste.

  ## The clock is the shader's business, not the mount's

  `data-daylight` tells the hook to feed the local day fraction into `u.lens.x`.
  It is derived here from `bg.shader` rather than set by whoever renders the
  canvas — see `Appearance.needs_daylight?/1`. It used to be a literal on the one
  mount that ran `daycycle`, which worked exactly as long as that shader could
  not be selected anywhere else.

  ## The id is a remount key, not a name

  `phx-update="ignore"` means LiveView never patches inside this div, so the
  hook keeps its GPU device across re-renders. The flip side is that a *changed*
  background can only take effect by remounting the hook — which is what the
  hashed id does. Everything the hook reads at mount (the shader, its palette,
  and now the image) is folded into that id, so changing any of them destroys
  the old canvas and boots a new one. **Leave a field out of the key and that
  setting silently stops applying** until a page reload.
  """
  use Phoenix.Component

  @doc """
  Render `bg`'s shader canvas, or nothing when `bg` is not shader-backed.

  `bg` is a `BusterClaw.Appearance.background/1` map. Both shader-backed kinds
  render here: `:shader` (a pattern alone) and `:image_shader` (a pattern
  sampling the selected image, which rides along as `data-image-url`).
  """
  attr :bg, :map, required: true

  attr :prefix, :string,
    required: true,
    doc: "id prefix, e.g. \"home\" / \"terminal\" / \"split\""

  attr :class, :string, default: "ic-shader-fill"
  attr :render?, :boolean, default: true, doc: "extra caller-side condition (e.g. not embedded?)"

  def shader_canvas(assigns) do
    ~H"""
    <div
      :if={@render? and shader_backed?(@bg)}
      id={dom_id(@prefix, @bg)}
      phx-hook="SmokeBackground"
      phx-update="ignore"
      data-shader={@bg.shader}
      data-daylight={to_string(BusterClaw.Appearance.needs_daylight?(@bg.shader))}
      data-shader-source={@bg.source_url}
      data-custom={to_string(@bg.custom)}
      data-colors={Enum.join(@bg.colors, ",")}
      data-image-url={@bg[:image_url]}
      class={@class}
      aria-hidden="true"
    >
      <canvas data-smoke-canvas></canvas>
    </div>
    """
  end

  @doc "Whether `bg` draws through a shader canvas at all."
  def shader_backed?(%{kind: kind}), do: kind in [:shader, :image_shader]
  def shader_backed?(_bg), do: false

  # The image url is in the key deliberately: swapping which image an
  # image-reactive shader samples changes nothing else about the background, so
  # without it the hook would keep the old picture bound and the change would
  # look like it had been ignored.
  defp dom_id(prefix, bg) do
    "#{prefix}-shader-#{bg.shader}-#{:erlang.phash2({bg.custom, bg.colors, bg[:image_url]})}"
  end
end
