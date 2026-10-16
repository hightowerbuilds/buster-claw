defmodule BusterClawWeb.WorkspaceRail do
  @moduledoc """
  The Workspace file tree's width. The operator drags the handle; the hook sets
  the width live and commits it on release (`rail_resize`); this clamps it and
  the template renders it, so a re-render never snaps the rail back.
  """
  use BusterClawWeb, :html

  @default 320
  @min 192
  @max 720

  def default_width, do: @default

  @doc "A requested width in px, clamped; anything that is not a number keeps `current`."
  def clamp_width(value, _current) when is_number(value),
    do: value |> round() |> max(@min) |> min(@max)

  def clamp_width(value, current) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_width(n, current)
      :error -> current
    end
  end

  def clamp_width(_value, current), do: current

  attr :open, :boolean, required: true

  def handle(assigns) do
    ~H"""
    <div
      :if={@open}
      data-rail-handle
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize file tree"
      title="Drag to resize"
      tabindex="0"
      class="w-1.5 shrink-0 cursor-col-resize rounded-sm transition hover:bg-primary/40 focus-visible:bg-primary/40 focus-visible:outline-none"
    >
    </div>
    """
  end
end
