defmodule BusterClaw.Sketch.Placement do
  @moduledoc """
  How big a placed image should be, and what to say when one is refused.

  Pure, and split out of `SketchComponent` because both halves are about to have
  a second caller: Phase 3's `sketch_import` places an image the same way a drop
  does, and must refuse one in the same words. Two implementations of "what size
  is this" would be two answers to a question the operator sees.

  Nothing here touches a socket, a file or a document — that is the point. The
  component keeps the parts that do.
  """

  # The longest side a placed image is scaled to fit. A phone screenshot is
  # 1179px wide and the panel is not.
  @max_placed 420

  @doc "The box a placed image should occupy, preserving its aspect ratio."
  @spec fit(number(), number()) :: {float(), float()}
  def fit(width, height)
      when is_number(width) and is_number(height) and width > 0 and height > 0 do
    # A distorted image is worse than a small one, so both axes take the same
    # scale — and it is capped at 1.0 so a small image is never blown up to fill
    # the box it was merely allowed to fit inside.
    scale = min(1.0, min(@max_placed / width, @max_placed / height))

    {Float.round(width * scale, 1), Float.round(height * scale, 1)}
  end

  @doc "The longest side a placed image is scaled to fit."
  def max_placed, do: @max_placed

  @doc """
  Where an image should sit so it is *centred* on the point it was dropped at.

  Centred rather than corner-anchored because you point at where you want the
  picture, not at where its top-left corner should be. Clamped at the origin so
  a drop near an edge does not put most of the image off the paper.
  """
  @spec origin({number(), number()}, {number(), number()}) :: {float(), float()}
  def origin({x, y}, {w, h}) do
    {max(x - w / 2, 0) / 1, max(y - h / 2, 0) / 1}
  end

  @doc """
  One sentence for a refusal, whatever produced it.

  The reasons are the server's own vocabulary. The dropzone hook sends them back
  as strings for its client-side refusals, so this takes either — and converts
  with `to_existing_atom` so a crafted payload cannot mint atoms, falling through
  to the generic sentence for anything unrecognised.
  """
  @spec humanize(atom() | String.t(), pos_integer(), pos_integer()) :: String.t()
  def humanize(reason, max_bytes, max_files)

  def humanize(:too_large, max_bytes, _files),
    do: "it is bigger than #{div(max_bytes, 1024 * 1024)} MB"

  def humanize(:unsupported, _bytes, _files), do: "it is not a PNG, JPEG, GIF or WebP"
  def humanize(:unsupported_type, _bytes, _files), do: "it is not a PNG, JPEG, GIF or WebP"
  def humanize(:empty, _bytes, _files), do: "it is empty"
  def humanize(:not_found, _bytes, _files), do: "the file could not be found"
  def humanize(:not_a_file, _bytes, _files), do: "it is not a file"
  def humanize(:too_many, _bytes, max_files), do: "only #{max_files} at a time"
  def humanize(:bad_filename, _bytes, _files), do: "its name could not be used"

  def humanize(reason, max_bytes, max_files) when is_binary(reason),
    do: humanize(safe_atom(reason), max_bytes, max_files)

  def humanize(_reason, _bytes, _files), do: "it could not be read"

  defp safe_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end
end
