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
  A byte count a person can read.

  Moved here from `MusicComponent` on 08-16, when the music library manager was
  deleted: two survivors used it — the detail pane's facts row and the info
  modal — and a pure formatter surviving inside a deleted module is how a
  deletion turns into a compile error at the worst moment. This module is
  already where the rest of this tab's pure presentation lives.
  """
  def humanize_bytes(nil), do: "—"
  def humanize_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"

  def humanize_bytes(bytes) when bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  def humanize_bytes(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def humanize_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

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

  @doc """
  A render refusal, as a sentence.

  Moved out of `SoundStudioComponent` on 08-16 to pay for the `duplicate_clip`
  handler: that file is FROZEN, so a new feature has to be funded by an
  extraction rather than a raised cap. This is the right kind to move — it is
  pure presentation over `Studio.Render`'s error atoms, with no assigns and no
  socket, which is exactly what this module already collects.

  The catch-all is deliberate and stays: `Render` can surface a `:file.posix()`
  from a failed write, and "Couldn't render that mix" beats showing `:enospc` to
  someone who wanted a sound.
  """
  def render_error(:empty_mix), do: "Add a clip before rendering."

  def render_error(:all_silenced),
    do: "Every clip is muted — unmute or solo something first."

  def render_error(:missing_source), do: "A clip's source is missing — nothing was rendered."
  def render_error(:too_long), do: "That arrangement is longer than five minutes."
  def render_error(:format_mismatch), do: "Those clips don't share a format."
  def render_error(_other), do: "Couldn't render that mix."

  @doc "The shared class for a row in the sidebar's right-click menu."
  def menu_item_class,
    do:
      "block w-full whitespace-nowrap px-3 py-1.5 text-left font-mono text-xs hover:bg-base-content/10"
end
