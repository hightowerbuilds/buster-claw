defmodule BusterClaw.Commands.Catalog.Sketch do
  @moduledoc """
  Catalog entries for the Sketch Pad (`SKETCH_ROADMAP` Phase 2, "the model can
  read one").

  **Two verbs, both reads, and the absence of a third is the phase.** Phase 3
  adds the write half behind `D6` — the model may change and delete what the
  model authored, and touching an operator's mark is gated. Shipping those before
  anyone has watched a model describe a drawing correctly would be building the
  write path on an untested representation.

  ## Why the descriptions insist on the picture

  `sketch_get` returns the element list and a rendered PNG, and the description
  says so plainly, because a model that reads only the JSON will answer
  confidently about a drawing it has not looked at. The list says what is
  addressable; the picture says what it looks like. Both, every time.
  """

  @doc "Sketch catalog entries."
  def entries,
    do: [
      %{
        name: "sketch_list",
        type: :read,
        tier: :safe,
        description:
          "Every sketch the operator has, with the name you pass to sketch_get, how many marks are on it, who made them (a count per author — operator or model), and when it last changed. A sketch is a drawing surface the operator and the model share: freehand strokes and images, each an addressable element with its own id. A sketch whose file will not parse is reported WITH an error rather than omitted, because an unreadable drawing is one the operator still has. Read this before answering anything about what the operator has drawn.",
        args: %{}
      },
      %{
        name: "sketch_get",
        type: :read,
        tier: :safe,
        description:
          "One sketch, in both the forms you need to reason about it. elements is the list — every mark with its id, its author, its colour and width or its image source, and the box it occupies; the id is what a later phase will use to change or remove it. preview is a PATH to a rendered PNG of the whole drawing: OPEN IT. The list tells you what is there and the picture tells you what it looks like — which marks overlap, which are illegible, where the empty space is — and answering from the list alone is how you end up describing a drawing you have not seen. A stroke's individual coordinates are deliberately NOT returned: a freehand mark is hundreds of points that say nothing you can act on, so it carries a point count and a bounding box instead. preview may be null with preview_error set when the drawing could not be rasterised; the elements are still correct, so say what is there and say you could not see it. Pass preview false to skip rendering when you only want the data.",
        args: %{
          "name" => %{type: :string, required: true},
          "preview" => %{type: :boolean, required: false}
        }
      }
    ]
end
