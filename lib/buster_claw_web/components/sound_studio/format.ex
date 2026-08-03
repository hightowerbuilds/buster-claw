defmodule BusterClawWeb.SoundStudio.Format do
  @moduledoc """
  How the Sound Studio writes durations, levels, and clip labels.

  Extracted from `SoundStudioComponent` (CODE_QUALITY_REFACTOR Phase 3B, 08-03).
  Pure string formatting with no assigns and no socket, used ~25 times across
  that module's template — so it was both the most-called code in the file and
  the least testable, because reaching it meant rendering a LiveComponent.

  `import`ed by the component, so every call site reads exactly as it did.
  """

  @doc """
  A duration in milliseconds, written the way a person reads it: `nil` is an
  em dash rather than `0 ms` (unknown and instant are different), sub-second
  values stay in milliseconds, and anything longer becomes seconds to two
  places.
  """
  def ms(nil), do: "—"
  def ms(value) when value < 1_000, do: "#{round(value)} ms"
  def ms(value), do: "#{Float.round(value / 1000, 2)} s"

  @doc """
  A peak level as dBFS. Zero or below is `"silent"` rather than `-∞ dBFS`,
  which is both truer to what the reader wants and avoids `log10(0)`.
  """
  def dbfs(nil), do: "—"
  def dbfs(peak) when peak <= 0, do: "silent"
  def dbfs(peak), do: "#{Float.round(20 * :math.log10(peak), 1)} dBFS"

  @doc """
  A clip's display label, derived from its source id rather than stored.

  Deriving it renames nothing and stays correct when the catalog changes
  underneath — a stored label would be a second copy of the truth.
  """
  def clip_label(%{source: source}) do
    source |> String.split(":", parts: 2) |> List.last() |> Path.rootname()
  end

  @doc "A clip's hover title: where it starts and how long it runs."
  def clip_title(%{source: source, start_ms: at, duration_ms: dur}) do
    "#{source} · starts #{ms(at)} · #{ms(dur)} long"
  end

  @doc "The shared class for a row in the sidebar's right-click menu."
  def menu_item_class,
    do:
      "block w-full whitespace-nowrap px-3 py-1.5 text-left font-mono text-xs hover:bg-base-content/10"
end
