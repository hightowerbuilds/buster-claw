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

  # The label face, and the three ratios everything about text is estimated with.
  # No quotes in the stack, because this string goes into an SVG attribute in the
  # standalone document and a nested `"` would end it.
  @font_family "IBM Plex Sans, ui-sans-serif, system-ui, sans-serif"

  # Ascent, line height, and average advance per character as fractions of the
  # font size. All three are guesses — nothing in the BEAM can measure a glyph —
  # and they live here rather than in either renderer so the two cannot guess
  # differently, which is the same reason `path_data/1` lives here.
  @ascent 0.8
  @line_height 1.2
  @advance 0.6

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

  @doc "The font stack a label is drawn in, in both renderers."
  def font_family, do: @font_family

  @doc """
  Where a label's baseline sits, given that its `y` is the TOP of its box.

  SVG's own `y` on a `<text>` is the baseline; every other element kind here is
  placed by its top-left corner. One of the two had to bend, and it was SVG's:
  "click here to put a label" should mean what it already means for an image,
  and an operator who places text at `y: 0` should see it rather than have it
  hang off the top of the panel.

  The cost is that `y` in the file is not the `y` in the markup, so a hand-edited
  sketch reads slightly differently than it renders. That is one indirection in
  one place against a placement rule that is wrong for every gesture.
  """
  def text_baseline(%Element{y: y, size: size}), do: round1(y + size * @ascent)

  @doc """
  A label's approximate width, and it is only ever approximate.

  Nothing server-side can measure a glyph, so this counts characters. A line of
  Ws overflows the estimate and a line of i's leaves slack. Both places that
  need it — a preview's extent, and a hit target you can click — degrade
  gracefully when it is a little wrong, which is why an estimate is allowed to
  be the answer here and would not be for, say, a layout.
  """
  def text_width(%Element{content: content, size: size}) when is_binary(content) do
    round1(String.length(content) * size * @advance)
  end

  def text_width(_element), do: 0.0

  @doc "A label's box height — one line, since `Element` refuses control characters."
  def text_height(%Element{size: size}), do: round1(size * @line_height)

  # Every derived number here goes through the same rounding the coordinates
  # do. Not cosmetic: `18 * 1.2` is 21.599999999999998 as a double, and `num/1`
  # prints the SHORTEST string that round-trips — so the honest answer is
  # seventeen digits of noise in an attribute, repeated on every element.
  defp round1(n), do: Float.round(n / 1, 1)

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

  defp element(%Element{kind: :text} = el, _sketch) do
    ~s(<text x="#{num(el.x)}" y="#{num(text_baseline(el))}" fill="#{el.color}" ) <>
      ~s(font-size="#{num(el.size)}" font-family="#{@font_family}">#{escape(el.content)}</text>)
  end

  defp element(_el, _sketch), do: ""

  # `content` is the only field on any element that lands as SVG **text
  # content** rather than inside an attribute — and from Phase 3 on it arrives
  # from a model. `Element` trims it, caps its length and strips control
  # characters; it deliberately does not strip markup, because escaping belongs
  # to whoever is building the document and there are two of those.
  #
  # Hand-rolled rather than `Phoenix.HTML.html_escape/1`: this module is web-free
  # on purpose (see the moduledoc — a command renders headlessly and must not
  # reach into `BusterClawWeb`), and importing Phoenix.HTML for five replacements
  # would buy that dependency back for nothing.
  #
  # `&` first, or the ampersands the later clauses introduce get escaped again.
  #
  # Quotes are escaped too, which text content does not require. The cost is a
  # few characters nobody reads; the alternative is that the day this string is
  # moved into an attribute, the escape quietly stops being enough and nothing
  # says so.
  defp escape(content) when is_binary(content) do
    content
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape(_content), do: ""

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

  # Without this a sketch that is nothing but a label renders at the floor size
  # and the label falls outside it — a preview of a blank rectangle, which is
  # worse than a preview that is a little too generous.
  defp element_extent(%Element{kind: :text} = el),
    do: {el.x + text_width(el), el.y + text_height(el)}

  defp element_extent(_element), do: {0.0, 0.0}
end
