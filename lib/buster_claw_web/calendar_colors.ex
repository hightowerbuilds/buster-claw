defmodule BusterClawWeb.CalendarColors do
  @moduledoc """
  Shared event-color treatments for the calendar, so every surface renders the
  same category hues.

  Each event `color` ("work" / "personal" / "social" / "travel" / "health" /
  "holiday" / "neutral", or nil) maps to a daisyUI semantic color; unknown/nil
  falls back to the brand primary. Class strings are full literals (never
  interpolated) so Tailwind's source scanner picks them up.

  The one consumer today is `CalendarComponent`, which uses `cell_wash/1`,
  `chip/1` and `swatch/1`. This module was written for two surfaces — it used to
  claim the home corner-widget month grid as the second — but `HomeWidget` never
  referenced it, and the two treatments only that grid would have needed
  (a strong whole-cell fill, and a text-only hue) were deleted on 08-09 rather
  than kept against a caller that never arrived. Re-add a treatment when a
  surface asks for it; the shape is four lines.
  """

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
