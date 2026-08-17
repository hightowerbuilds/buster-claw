defmodule BusterClaw.Sketch.Svg do
  @moduledoc """
  A sketch as SVG, with no web layer involved.

  `Studio.SketchSvg` renders the live surface with HEEx and owns the interactive
  parts — hit targets, selection rings, the hook's in-flight layer. This is the
  half that is just geometry, and it moved here when Phase 2 needed to render a
  sketch **headlessly**: a `sketch_get` command runs in the BEAM with no socket
  and no request, and a command module reaching into `BusterClawWeb` would be
  the dependency pointing the wrong way.

  So `path_data/1` has one home and two callers rather than two copies.

  ## `document/2` is a rendering, not a record

  `to_document/2` produces a standalone SVG file for rasterizing. It differs from
  the live surface in one deliberate way: **images are embedded as data URIs.**
  The sketch document itself never carries bytes — that is `D11` and it is what
  keeps the JSON diffable — but a preview is a throwaway picture rather than a
  record, and a self-contained file is the only kind a rasterizer can be handed
  without also granting it the ability to follow references out of the folder.
  """

  alias BusterClaw.Sketch.{Document, Element, ImageInfo, Paths}

  @doc """
  Points to an SVG path.

  **Must agree byte-for-byte with `pathData` in `assets/js/lib/sketch.js`.** The
  hook draws a stroke while it is being made and the server draws it the instant
  it commits; a disagreement is a visible jump at the end of every stroke. Both
  are tested on the same cases.
  """
  def path_data([]), do: ""

  # A tap with no movement is a dot, not nothing — a zero-length path does not
  # render even with a round linecap.
  def path_data([[x, y]]), do: "M #{num(x)} #{num(y)} L #{num(x)} #{num(y)}"

  def path_data([[x, y] | rest]) do
    "M #{num(x)} #{num(y)} " <>
      Enum.map_join(rest, " ", fn [px, py] -> "L #{num(px)} #{num(py)}" end)
  end

  def path_data(_points), do: ""

  @doc """
  Format a number the way an SVG attribute should carry it.

  Elements store floats, so a whole number is `0.0` here and `0` in JavaScript.
  Printing `0.0` would be a valid path and a mismatched string, which is exactly
  the drift the agreement test exists to catch.
  """
  def num(n) when is_float(n) do
    if n == Float.round(n),
      do: Integer.to_string(trunc(n)),
      else: :erlang.float_to_binary(n, [:short])
  end

  def num(n) when is_integer(n), do: Integer.to_string(n)

  @doc """
  A standalone SVG document for `doc`, sized to fit what is on it.

  `background` is painted first so a rasterizer produces the drawing as it looks
  in the app rather than as strokes on transparency.
  """
  def to_document(%Document{} = doc, opts \\ []) do
    background = Keyword.get(opts, :background, "#1a1a1a")
    sketch = Keyword.get(opts, :sketch)

    # SQUARE, and this is not cosmetic. The rasteriser is a thumbnailer and boxes
    # its output, so a 504x304 drawing came back with a white L filling the rest
    # of the frame — which a model reading the picture can reasonably describe as
    # part of the drawing. Squaring the canvas here makes that region the
    # sketch's own background instead. Nothing moves and nothing distorts: the
    # coordinates are unchanged and only paper is added.
    {width, height} = extent(doc)
    side = max(width, height)

    body = Enum.map_join(doc.elements, "\n  ", &element(&1, sketch))

    """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
    width="#{num(side)}" height="#{num(side)}" viewBox="0 0 #{num(side)} #{num(side)}">
      <rect width="100%" height="100%" fill="#{background}"/>
      #{body}
    </svg>
    """
  end

  @doc """
  The bounding size of everything on the document, padded, with a floor.

  A sketch has no canvas size of its own — one user unit is one CSS pixel and the
  panel decides what is visible — so a rendering has to derive one. An empty
  document still gets the floor rather than a zero-sized SVG, which no rasterizer
  renders.
  """
  def extent(%Document{elements: []}), do: {640.0, 480.0}

  def extent(%Document{elements: elements}) do
    {max_x, max_y} =
      Enum.reduce(elements, {0.0, 0.0}, fn element, {mx, my} ->
        {ex, ey} = element_extent(element)
        {max(mx, ex), max(my, ey)}
      end)

    {Float.round(max(max_x + 24, 320.0), 1), Float.round(max(max_y + 24, 240.0), 1)}
  end

  # --- elements -------------------------------------------------------------

  defp element(%Element{kind: :stroke} = el, _sketch) do
    ~s(<path d="#{path_data(el.points)}" stroke="#{el.color}" stroke-width="#{num(el.width)}" ) <>
      ~s(fill="none" stroke-linecap="round" stroke-linejoin="round"/>)
  end

  defp element(%Element{kind: :image} = el, sketch) do
    ~s(<image x="#{num(el.x)}" y="#{num(el.y)}" width="#{num(el.w)}" height="#{num(el.h)}" ) <>
      ~s(preserveAspectRatio="none" xlink:href="#{data_uri(sketch, el.source)}"/>)
  end

  defp element(_el, _sketch), do: ""

  # Embedded rather than referenced — see the moduledoc. A missing or unreadable
  # asset yields an empty href rather than raising: a preview with one picture
  # missing is more useful than no preview.
  defp data_uri(nil, _source), do: ""

  defp data_uri(sketch, source) do
    with {:ok, path} <- Paths.asset(sketch, source),
         {:ok, bytes} <- File.read(path),
         {:ok, %{format: format}} <- ImageInfo.inspect_binary(bytes) do
      "data:#{ImageInfo.media_type(format)};base64,#{Base.encode64(bytes)}"
    else
      _ -> ""
    end
  end

  defp element_extent(%Element{kind: :stroke, points: points, width: width})
       when is_list(points) do
    half = (width || 0) / 2

    Enum.reduce(points, {0.0, 0.0}, fn [x, y], {mx, my} ->
      {max(mx, x + half), max(my, y + half)}
    end)
  end

  defp element_extent(%Element{kind: :image, x: x, y: y, w: w, h: h}), do: {x + w, y + h}
  defp element_extent(_element), do: {0.0, 0.0}
end
