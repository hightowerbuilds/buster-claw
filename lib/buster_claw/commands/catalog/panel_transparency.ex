defmodule BusterClaw.Commands.Catalog.PanelTransparency do
  @moduledoc """
  Catalog entries for panel transparency — how see-through the Work Area's
  panels and sidebar are over the background (10-17).

  The read is `:safe`: it reports one number already visible on the operator's
  own Appearance page. The write is `:restricted` and **not gated**, by the
  same argument `background_set` makes: it writes one setting, touches no file,
  sends nothing outbound, is visible the instant it happens, and is undone by
  one more call or one drag of the slider. Its worst case is legibility, and the
  blur stays at every value, so text keeps an edge even at 100.
  """

  @doc "Panel transparency catalog entries."
  def entries,
    do: [
      %{
        name: "panel_transparency_get",
        type: :read,
        tier: :safe,
        description:
          "How see-through the Work Area's panels are right now — `percent` from 0 (solid) to 100 (no fill, only the blur), plus the default and the range. The same value as the slider in Settings → Appearance → Panel transparency.",
        args: %{}
      },
      %{
        name: "panel_transparency_set",
        type: :mutate,
        tier: :restricted,
        description:
          "Make the Work Area's panels and sidebar more or less see-through over the background, live — no reload. `percent` is 0 (solid) to 100 (no fill, only the blur); 32 is the shipped look. Higher shows more of the background shader or image and makes busy backgrounds harder to read over, so say what you are changing and why.",
        args: %{
          "percent" => %{
            type: :integer,
            required: true,
            description: "0 (solid) to 100 (no fill, only the blur). 32 is the default."
          }
        }
      }
    ]
end
