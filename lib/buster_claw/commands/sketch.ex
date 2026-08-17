defmodule BusterClaw.Commands.Sketch do
  @moduledoc """
  The `sketch_*` command surface — the model's **read** access to the Sketch Pad
  (`SKETCH_ROADMAP` Phase 2). Delegated to from `BusterClaw.Commands`.

  ## Two verbs, both reads, and deliberately no more yet

  `sketch_list` says what exists and `sketch_get` returns one. **Nothing here
  writes**, and the absence is the phase: Phase 3 adds `sketch_add`,
  `sketch_update` and `sketch_delete` behind `D6`'s authorship boundary, and
  putting them in before the read half has been used would mean shipping the
  write path before anyone has checked that the model can describe a drawing
  correctly. That check is the cheapest possible proof the representation works,
  and it is worth stopping for.

  `test/buster_claw/commands/sketch_test.exs` fails if a verb that mutates
  appears here before then — the same shape as the guard that keeps a mutating
  verb out of Pockets.

  ## Both representations, because neither is sufficient

  `sketch_get` returns the element list **and** the path to a rendered PNG
  (`D4`). The JSON says what is addressable — every element carries the id Phase
  3 will need to change or remove it — and the picture says what it actually
  looks like. Every system surveyed in Part I sends both, and the reason is that
  a model given only JSON produces tidy data and ugly drawings.

  The preview is a **path**, not bytes. An agent CLI can open a file; a base64
  blob in a command result would spend the operator's context on something they
  did not ask to read. It is also optional: rendering leans on a macOS
  thumbnailer that has never run in a packaged build, so a sketch whose picture
  could not be drawn still returns its elements, with `preview_error` saying why.

  ## Why both are `:safe`

  They read files under the workspace's `sketches/` directory, write nothing,
  change no setting and send nothing. Names go through `Sketch.Paths`, whose
  allowlist admits nothing shaped like a path, and asset names are checked the
  same way — there is no path building here at all.
  """

  alias BusterClaw.Sketch.{Document, Preview, Store}

  @doc """
  Every sketch, with enough to choose one: how many marks, who made them, when.
  """
  def sketch_list(_args \\ %{}) do
    sketches =
      Store.list()
      |> Enum.map(fn name ->
        case Store.load(name) do
          {:ok, doc} ->
            %{
              name: name,
              title: doc.title,
              elements: Document.size(doc),
              authors: authors(doc),
              updated_at: doc.updated_at
            }

          # A sketch that will not parse is still one the operator has. Reporting
          # it as unreadable beats omitting it, which would read as "deleted".
          {:error, reason} ->
            %{name: name, error: to_string(reason)}
        end
      end)

    {:ok, %{sketches: sketches, count: length(sketches)}}
  end

  @doc """
  One sketch: its elements, and a rendered picture of them.

  Takes `name`; `preview: false` skips rasterising when only the data is wanted.
  """
  def sketch_get(%{"name" => name} = args) when is_binary(name) do
    case Store.load(name) do
      {:ok, doc} ->
        {:ok, describe(name, doc, Map.get(args, "preview", true))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sketch_get(_args), do: {:error, :missing_name}

  # --- internals ------------------------------------------------------------

  defp describe(name, doc, preview?) do
    base = %{
      name: name,
      title: doc.title,
      elements: Enum.map(doc.elements, &element/1),
      count: Document.size(doc),
      authors: authors(doc),
      updated_at: doc.updated_at
    }

    if preview?, do: Map.merge(base, preview(name, doc)), else: base
  end

  defp preview(name, doc) do
    case Preview.render(name, doc) do
      {:ok, path} -> %{preview: path}
      {:error, reason} -> %{preview: nil, preview_error: to_string(reason)}
    end
  end

  # The id leads every element because it is the thing Phase 3 acts on, and the
  # author is beside it because `D6` decides what the model may touch by who made
  # it. A representation that omitted either would be one the write phase could
  # not be built on.
  defp element(%{kind: :stroke} = el) do
    %{
      id: el.id,
      kind: "stroke",
      author: Atom.to_string(el.author),
      color: el.color,
      width: el.width,
      points: length(el.points),
      bounds: bounds(el)
    }
  end

  defp element(%{kind: :image} = el) do
    %{
      id: el.id,
      kind: "image",
      author: Atom.to_string(el.author),
      source: el.source,
      bounds: %{x: el.x, y: el.y, w: el.w, h: el.h}
    }
  end

  # A stroke's points are summarised rather than listed. A freehand mark is
  # hundreds of coordinates that say nothing a model can act on — Phase 3 moves
  # and deletes whole elements, it does not edit vertices — and dumping them
  # would spend most of the reply on noise. The count and the box are what
  # "where is it, and how big" actually needs.
  defp bounds(%{points: points}) when is_list(points) and points != [] do
    {xs, ys} = points |> Enum.map(fn [x, y] -> {x, y} end) |> Enum.unzip()

    %{
      x: Enum.min(xs),
      y: Enum.min(ys),
      w: Float.round(Enum.max(xs) - Enum.min(xs), 1),
      h: Float.round(Enum.max(ys) - Enum.min(ys), 1)
    }
  end

  defp bounds(_element), do: %{x: 0, y: 0, w: 0, h: 0}

  defp authors(%Document{elements: elements}) do
    elements |> Enum.map(&Atom.to_string(&1.author)) |> Enum.frequencies()
  end
end
