defmodule BusterClawWeb.CalendarColors do
  @moduledoc """
  Shared event-color treatments for the calendar, so every surface renders the
  same category hues.

  Each event `color` ("work" / "personal" / "social" / "travel" / "health" /
  "holiday" / "neutral", or nil) maps to a daisyUI semantic color; unknown/nil
  falls back to the brand primary. Class strings are full literals (never
  interpolated) so Tailwind's source scanner picks them up.

  The one consumer today is `CalendarComponent`, which uses `bar/1` and
  `swatch/1` since its Minimal restyle (10-17). The filled treatments it used
  before — `chip/1` (a tinted pill) and `cell_wash/1` (a tinted day cell) — were
  deleted with it, by the rule below. This module was written for two surfaces — it used to
  claim the home corner-widget month grid as the second — but `HomeWidget` never
  referenced it, and the two treatments only that grid would have needed
  (a strong whole-cell fill, and a text-only hue) were deleted on 08-09 rather
  than kept against a caller that never arrived. Re-add a treatment when a
  surface asks for it; the shape is four lines.
  """

  # Left bar — the Minimal treatment (10-17): an event is a line of text with
  # its category as a 2px rule on the left, the way the chat's Minimal skin
  # marks a prompt. Paired with `border-l-2` in the markup.
  @bar %{
    "neutral" => "border-base-content/40",
    "work" => "border-info",
    "personal" => "border-secondary",
    "social" => "border-accent",
    "travel" => "border-warning",
    "health" => "border-success",
    "holiday" => "border-error"
  }
  def bar(color), do: Map.get(@bar, color, "border-primary")

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
