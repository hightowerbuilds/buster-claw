defmodule BusterClaw.Commands.PanelTransparency do
  @moduledoc """
  The `panel_transparency_*` command surface — the model makes the Work Area's
  panels more or less see-through, the same control as Settings → Appearance →
  Panel transparency.

  Two verbs: read the value in force, set a new one. `BusterClaw.PanelTransparency`
  owns the range, the default, the storage and the broadcast; this module turns
  its answers into wire-shaped maps and its refusals into sentences. Like
  `background_set`, there is no announce step: `set/1` broadcasts itself and an
  open Work Area restyles live.
  """

  alias BusterClaw.PanelTransparency

  @doc "The transparency in force, the default, and the range."
  def panel_transparency_get(_args \\ %{}) do
    {:ok, report(PanelTransparency.get())}
  end

  @doc """
  Set the transparency, live. `percent` is 0 (solid) to 100 (no fill, only the
  blur); `default` puts back the shipped look.
  """
  def panel_transparency_set(%{"percent" => "default"}),
    do: panel_transparency_set(%{"percent" => PanelTransparency.default()})

  def panel_transparency_set(%{"percent" => percent}) do
    case PanelTransparency.set(percent) do
      {:ok, n} -> {:ok, Map.put(report(n), :applied, true)}
      {:error, :out_of_range} -> {:error, out_of_range(percent)}
      {:error, :not_a_number} -> {:error, not_a_number(percent)}
    end
  end

  def panel_transparency_set(_args),
    do:
      {:error,
       "panel_transparency_set needs `percent`: a whole number from 0 (solid panels) " <>
         "to 100 (no fill, only the blur), or \"default\" for #{PanelTransparency.default()}."}

  defp report(n) do
    %{
      percent: n,
      default: PanelTransparency.default(),
      min: Enum.min(PanelTransparency.range()),
      max: Enum.max(PanelTransparency.range()),
      panel_fill: PanelTransparency.fills(n).panel
    }
  end

  defp out_of_range(percent),
    do:
      "#{inspect(percent)} is outside 0–100. 0 is a solid panel, 100 is no fill at all " <>
        "(only the blur); the default is #{PanelTransparency.default()}."

  defp not_a_number(percent),
    do:
      "#{inspect(percent)} is not a whole number. Send percent as an integer from 0 to 100, " <>
        "or \"default\"."
end
