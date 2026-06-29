defmodule BusterClawWeb.CalendarColors do
  @moduledoc """
  Shared event-color treatments for the two calendar surfaces — the home
  corner-widget month grid (`HomeWidget`) and the full calendar page
  (`CalendarLive`) — so both render the same category hues.

  Each event `color` ("work" / "personal" / "social" / "travel" / "health" /
  "holiday" / "neutral", or nil) maps to a daisyUI semantic color; unknown/nil
  falls back to the brand primary. Class strings are full literals (never
  interpolated) so Tailwind's source scanner picks them up.
  """

  # Strong whole-cell fill — the widget's compact month cells, where the cell
  # color IS the only event cue.
  @cell_fill %{
    "neutral" => "bg-base-content/20",
    "work" => "bg-info/35",
    "personal" => "bg-secondary/35",
    "social" => "bg-accent/35",
    "travel" => "bg-warning/35",
    "health" => "bg-success/35",
    "holiday" => "bg-error/35"
  }
  def cell_fill(color), do: Map.get(@cell_fill, color, "bg-primary/35")

  # Faint whole-cell wash — the full calendar's tall cells: a subtle "busy" tint
  # that sits under the event chips so a day reads colored at a glance.
  @cell_wash %{
    "neutral" => "bg-base-content/5",
    "work" => "bg-info/10",
    "personal" => "bg-secondary/10",
    "social" => "bg-accent/10",
    "travel" => "bg-warning/10",
    "health" => "bg-success/10",
    "holiday" => "bg-error/10"
  }
  def cell_wash(color), do: Map.get(@cell_wash, color, "bg-primary/10")

  # Event chip — a tinted pill with matching text, used inside cells and lists.
  @chip %{
    "neutral" => "bg-base-content/15 text-base-content",
    "work" => "bg-info/25 text-info",
    "personal" => "bg-secondary/25 text-secondary",
    "social" => "bg-accent/25 text-accent",
    "travel" => "bg-warning/25 text-warning",
    "health" => "bg-success/25 text-success",
    "holiday" => "bg-error/25 text-error"
  }
  def chip(color), do: Map.get(@chip, color, "bg-primary/25 text-primary")

  # Text-only hue (e.g. a time label whose row already has its own background).
  @text %{
    "neutral" => "text-base-content",
    "work" => "text-info",
    "personal" => "text-secondary",
    "social" => "text-accent",
    "travel" => "text-warning",
    "health" => "text-success",
    "holiday" => "text-error"
  }
  def text(color), do: Map.get(@text, color, "text-primary")

  # Solid swatch dot.
  @swatch %{
    "neutral" => "bg-base-content/40",
    "work" => "bg-info",
    "personal" => "bg-secondary",
    "social" => "bg-accent",
    "travel" => "bg-warning",
    "health" => "bg-success",
    "holiday" => "bg-error"
  }
  def swatch(color), do: Map.get(@swatch, color, "bg-primary")
end
