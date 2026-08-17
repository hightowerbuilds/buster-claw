defmodule BusterClaw.Sketch.Element do
  @moduledoc """
  One addressable thing on a sketch — and the gate everything crosses to become one.

  `SKETCH_ROADMAP` Phase 1. Only `:stroke` exists so far; the other kinds arrive
  with the phases that need them, and an unknown kind is refused rather than
  stored, so a document can never carry something no renderer knows how to draw.

  ## Why this is strict now, while only the operator can write

  Nothing here is defending against the operator. It is built for Phase 3, when
  `sketch_add` starts taking element JSON from a model — at which point every
  field below is untrusted input that ends up inside an SVG attribute. Writing
  the boundary now means it is exercised by the whole of Phase 1 before anything
  hostile arrives, rather than being added in the same sitting as the feature it
  guards. This repo has the lesson on file: a guard written beside its code
  inherits its blind spot.

  ## Ids are minted here and never accepted

  `new/1` **ignores any `id` in its input.** A caller-supplied id is the same
  class of input as a caller-supplied file path, and letting one through would
  let a writer overwrite an element it does not own by guessing its id — which is
  precisely what `D6`'s authorship boundary exists to prevent.

  ## Coordinates

  CSS pixels, absolute, in the panel's own space — one unit is one pixel, the way
  the raster version behaved. Resizing the panel reveals or hides paper rather
  than scaling what is on it, which keeps a stroke the size it was drawn.
  """

  @kinds ~w(stroke image text)a
  @authors ~w(operator model)a

  # Bounds, not preferences. Each one is the point past which a document stops
  # being renderable: an SVG path with a million points, a stroke wider than any
  # panel, a coordinate far enough out that it is effectively invisible but still
  # costs bytes on every load.
  @max_points 4_000
  @max_width 200
  @coord_limit 100_000

  @hex ~r/\A#[0-9A-Fa-f]{6}\z/
  @source_re ~r/\A[0-9a-f]{16}\.(png|jpg|gif|webp)\z/

  # An image bigger than this is not a placement, it is a mistake.
  @max_extent 20_000

  # A label, not a document. Text longer than this belongs in a note, and a
  # sketch that carries an essay is one the renderer cannot lay out anyway.
  @max_content 2_000
  @text_sizes [12, 18, 28, 48]

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :kind,
    :author,
    :created_at,
    :points,
    :color,
    :width,
    :source,
    :x,
    :y,
    :w,
    :h,
    :content,
    :size
  ]

  @doc "The element kinds that exist today. An unknown kind is refused."
  def kinds, do: @kinds

  @doc "The text sizes a label may use — a closed set, not a free number."
  def text_sizes, do: @text_sizes

  @doc """
  Build a validated element, minting its id. Returns `{:ok, element}` or
  `{:error, reason}` naming the first field that failed.

  Any `id` in `attrs` is ignored — see the moduledoc.
  """
  def new(attrs) when is_map(attrs) do
    attrs = normalize(attrs)

    with {:ok, kind} <- fetch_kind(attrs),
         {:ok, author} <- fetch_author(attrs),
         {:ok, built} <- build(kind, attrs) do
      {:ok, %{built | id: mint_id(), kind: kind, author: author, created_at: DateTime.utc_now()}}
    end
  end

  def new(_attrs), do: {:error, :not_a_map}

  @doc """
  Re-validate an element read back from disk, keeping its stored id, author and
  timestamp.

  A sketch file lives in the operator's workspace, so it is hand-editable by
  design — which makes loading one an untrusted read, not a trusted one. A file
  that has been edited into something unrenderable should lose that element and
  keep the rest, rather than take the whole sketch down.
  """
  def rehydrate(attrs) when is_map(attrs) do
    attrs = normalize(attrs)

    with {:ok, kind} <- fetch_kind(attrs),
         {:ok, author} <- fetch_author(attrs),
         {:ok, id} <- fetch_id(attrs),
         {:ok, built} <- build(kind, attrs) do
      {:ok,
       %{built | id: id, kind: kind, author: author, created_at: parse_time(attrs["created_at"])}}
    end
  end

  def rehydrate(_attrs), do: {:error, :not_a_map}

  # --- per-kind construction ------------------------------------------------

  defp build(:stroke, attrs) do
    with {:ok, points} <- fetch_points(attrs),
         {:ok, color} <- fetch_color(attrs),
         {:ok, width} <- fetch_width(attrs) do
      {:ok, %__MODULE__{points: points, color: color, width: width}}
    end
  end

  # Text is a label placed at a point — no box, because it is sized by its own
  # content and the renderer measures it. Deliberately a small closed set of
  # sizes rather than a number: a free `font-size` invites a model to specify
  # 13.5px, which no one asked for and nothing else on the surface offers.
  defp build(:text, attrs) do
    with {:ok, content} <- fetch_content(attrs),
         {:ok, color} <- fetch_color(attrs),
         {:ok, size} <- fetch_size(attrs),
         {:ok, x} <- fetch_coord(attrs, "x"),
         {:ok, y} <- fetch_coord(attrs, "y") do
      {:ok, %__MODULE__{content: content, color: color, size: size, x: x, y: y}}
    end
  end

  # An image REFERENCES a file and never carries bytes (SKETCH_ROADMAP Phase 4).
  # A base64 blob in the document could not be diffed, grepped or read, and would
  # put arbitrary bytes into whatever the audit log captures.
  #
  # `source` is a bare filename inside the sketch's own sidecar, minted by
  # `Sketch.Assets` from a hash of the content. Validated here against the same
  # allowlist rather than trusted, because this is also the shape Phase 4's
  # `sketch_import` will hand over from a model.
  defp build(:image, attrs) do
    with {:ok, source} <- fetch_source(attrs),
         {:ok, x} <- fetch_coord(attrs, "x"),
         {:ok, y} <- fetch_coord(attrs, "y"),
         {:ok, w} <- fetch_extent(attrs, "w"),
         {:ok, h} <- fetch_extent(attrs, "h") do
      {:ok, %__MODULE__{source: source, x: x, y: y, w: w, h: h}}
    end
  end

  # --- field validation -----------------------------------------------------

  defp fetch_kind(%{"kind" => kind}) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:unknown_kind, kind}}
      known -> {:ok, known}
    end
  end

  defp fetch_kind(%{"kind" => kind}) when kind in @kinds, do: {:ok, kind}
  defp fetch_kind(_attrs), do: {:error, :missing_kind}

  # Defaults to :operator. Phase 1 has no other author, and a document that
  # silently claimed `:model` authorship would hand the model deletion rights
  # over the operator's own strokes (D6).
  defp fetch_author(%{"author" => author}) when is_binary(author) do
    case Enum.find(@authors, &(Atom.to_string(&1) == author)) do
      nil -> {:error, {:unknown_author, author}}
      known -> {:ok, known}
    end
  end

  defp fetch_author(%{"author" => author}) when author in @authors, do: {:ok, author}
  defp fetch_author(_attrs), do: {:ok, :operator}

  defp fetch_id(%{"id" => id}) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp fetch_id(_attrs), do: {:error, :missing_id}

  defp fetch_points(%{"points" => points}) when is_list(points) do
    cond do
      points == [] -> {:error, :empty_points}
      length(points) > @max_points -> {:error, :too_many_points}
      true -> validate_points(points)
    end
  end

  defp fetch_points(_attrs), do: {:error, :missing_points}

  defp validate_points(points) do
    Enum.reduce_while(points, {:ok, []}, fn point, {:ok, acc} ->
      case point do
        [x, y] when is_number(x) and is_number(y) ->
          if in_bounds?(x) and in_bounds?(y),
            do: {:cont, {:ok, [[round1(x), round1(y)] | acc]}},
            else: {:halt, {:error, :point_out_of_bounds}}

        _other ->
          {:halt, {:error, :malformed_point}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp in_bounds?(n), do: n >= -@coord_limit and n <= @coord_limit

  # One decimal is below what any display can resolve and roughly halves the
  # bytes a long freehand stroke costs in the file and in every LiveView diff.
  defp round1(n), do: Float.round(n / 1, 1)

  # An SVG attribute, so this is an allowlist rather than an escape. Nothing that
  # is not six hex digits after a `#` can reach the rendered document.
  defp fetch_color(%{"color" => color}) when is_binary(color) do
    if Regex.match?(@hex, color), do: {:ok, color}, else: {:error, {:bad_color, color}}
  end

  defp fetch_color(_attrs), do: {:error, :missing_color}

  defp fetch_width(%{"width" => width}) when is_number(width) do
    if width > 0 and width <= @max_width,
      do: {:ok, width / 1},
      else: {:error, :width_out_of_range}
  end

  defp fetch_width(_attrs), do: {:error, :missing_width}

  # The same allowlist `Sketch.Assets` mints against: sixteen hex digits and a
  # known extension. Nothing shaped like a path matches it, so there is no
  # traversal to strip — a name either is one of ours or it is refused.
  defp fetch_source(%{"source" => source}) when is_binary(source) do
    if Regex.match?(@source_re, source),
      do: {:ok, source},
      else: {:error, {:bad_source, source}}
  end

  defp fetch_source(_attrs), do: {:error, :missing_source}

  # Trimmed, length-capped, and stripped of control characters. It lands as SVG
  # TEXT CONTENT rather than an attribute, so the renderer escapes it — but a
  # newline or a NUL in a label is a rendering artefact nobody asked for, and the
  # cheapest place to refuse one is here.
  defp fetch_content(%{"content" => content}) when is_binary(content) do
    cleaned = content |> String.replace(~r/[\x00-\x1F\x7F]/, " ") |> String.trim()

    cond do
      cleaned == "" -> {:error, :empty_content}
      String.length(cleaned) > @max_content -> {:error, :content_too_long}
      true -> {:ok, cleaned}
    end
  end

  defp fetch_content(_attrs), do: {:error, :missing_content}

  defp fetch_size(%{"size" => size}) when is_number(size) do
    rounded = round(size)
    if rounded in @text_sizes, do: {:ok, rounded}, else: {:error, {:bad_size, size}}
  end

  defp fetch_size(_attrs), do: {:ok, hd(@text_sizes)}

  # Explicit error atoms rather than `String.to_existing_atom("missing_" <> key)`:
  # that would raise on the first miss (nothing has minted `:missing_x`) and, if
  # it did not, would be a way for map keys to reach the atom table.
  defp fetch_coord(attrs, "x"), do: coord(Map.get(attrs, "x"), :missing_x)
  defp fetch_coord(attrs, "y"), do: coord(Map.get(attrs, "y"), :missing_y)

  defp coord(n, _missing) when is_number(n) do
    if in_bounds?(n), do: {:ok, round1(n)}, else: {:error, :point_out_of_bounds}
  end

  defp coord(_value, missing), do: {:error, missing}

  defp fetch_extent(attrs, key) do
    case Map.get(attrs, key) do
      n when is_number(n) and n > 0 ->
        if n <= @max_extent, do: {:ok, round1(n)}, else: {:error, :extent_out_of_range}

      _ ->
        {:error, :extent_out_of_range}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp normalize(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Prefixed so an id is recognisable on sight in a file, a log line, or a model's
  # reply — and so a bare uuid from somewhere else is obviously not one of ours.
  defp mint_id do
    "el_" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(%DateTime{} = at), do: at
  defp parse_time(_value), do: DateTime.utc_now()
end
