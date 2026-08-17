defmodule BusterClaw.Commands.Catalog.Sketch do
  @moduledoc """
  Catalog entries for the Sketch Pad (`SKETCH_ROADMAP` Phases 2 and 3 — "the
  model can read one", then "the model can draw").

  **Two reads and four writes.** The reads are `:safe`; every write is
  `:restricted`.

  ## Why `sketch_delete` is NOT gated, when twelve of fourteen `*_delete` are

  It was, for an afternoon, and the flag made the feature impossible. `gated` is
  refused to `:agent_untrusted` by the PolicyEngine baseline — and
  `:agent_untrusted` is the *only* caller that is both permitted a `:restricted`
  command **and** treated as the model by `Authorship`. `:trusted` and
  `:terminal` are the operator; `:agent` and `:mcp` get nothing restricted at
  all. So with the flag set, **no caller could ever delete its own mark**, which
  is Phase 3's exit test and the opposite of what `D6` promises.

  The resolution is not a compromise, it is the point of `D6`. **`gated` is a
  statement about a VERB; `D6` is a statement about the DATA.** Here the
  data-level rule strictly dominates the verb-level one: an operator-authored
  element is refused with `:requires_confirmation` and surfaced for approval —
  everything blanket gating would have achieved — while the model's own false
  starts stay free to remove, which blanket gating made impossible.

  A blanket gate would have been the *weaker* protection wearing the stronger
  word. The thing worth protecting was never "delete" — it was "someone else's
  drawing", and that is what is protected.

  ## Why the descriptions insist on the picture

  `sketch_get` returns the element list and a rendered PNG, and the description
  says so plainly, because a model that reads only the JSON will answer
  confidently about a drawing it has not looked at. The list says what is
  addressable; the picture says what it looks like. Both, every time.

  ## Why the write descriptions insist on the boundary

  `D6` is not a policy the model can be talked out of — an operator-authored
  element is refused in code — but a model that does not *know* the rule spends
  its turn discovering it by being refused, and then apologises for a limit
  rather than working within it. So each write says plainly whose marks it may
  touch, and `sketch_update`/`sketch_delete` say what to do when refused: ask.

  They also say what is **not** accepted. A model that believes it chooses an
  element's `id` will write one, watch a different id come back, and then address
  the wrong element on its next call. Saying "the app mints it, read it from the
  reply" costs one clause and removes that whole failure.
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
      },
      %{
        name: "sketch_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Start a NEW empty sketch. name is the filename it lives under and the handle every other sketch_* verb takes: letters, digits, spaces, dashes and underscores, up to 64 characters, and nothing shaped like a path. title is the human label shown on the surface and defaults to the name. Refused with already_exists if a sketch of that name is already there — it will NOT overwrite one, and that refusal is a fact about the workspace, not a failure: use sketch_list to see what the operator already has, and prefer adding to an existing sketch over inventing a near-duplicate name. A new sketch is empty; put marks on it with sketch_add.",
        args: %{
          "name" => %{type: :string, required: true},
          "title" => %{type: :string, required: false}
        }
      },
      %{
        name: "sketch_add",
        type: :mutate,
        tier: :restricted,
        description:
          "Put one new mark on a sketch. It lands ON TOP of everything already there — list order is paint order — so add backgrounds before the things that sit on them. name says which sketch; kind says what the mark is, and each kind takes its own fields. kind text: content (the label, up to 2000 characters), x and y (the anchor point in pixels, y growing DOWNWARD from the top-left), color (#RRGGBB, six hex digits, nothing else), size (12, 18, 28 or 48 — a closed set, not a free number). kind stroke: points (a list of [x, y] pairs, in order, up to 4000 of them), color, width (1 to 200). kind image: source (a filename ALREADY in this sketch's sidecar — this verb places an image, it does not import one), x, y, w, h. DO NOT send an id or an author: the app mints the id and stamps the author, and both are returned to you — READ THE id FROM THE REPLY, because it is the only handle sketch_update and sketch_delete accept. Anything you add is yours to change or remove afterwards; see sketch_update. A field that fails validation refuses the whole call and names the field, so fix that field rather than re-sending the same shape.",
        args: %{
          "name" => %{type: :string, required: true},
          "kind" => %{type: :string, required: true},
          "content" => %{type: :string, required: false},
          "points" => %{type: :array, required: false},
          "color" => %{type: :string, required: false},
          "width" => %{type: :number, required: false},
          "size" => %{type: :number, required: false},
          "source" => %{type: :string, required: false},
          "x" => %{type: :number, required: false},
          "y" => %{type: :number, required: false},
          "w" => %{type: :number, required: false},
          "h" => %{type: :number, required: false}
        }
      },
      %{
        name: "sketch_update",
        type: :mutate,
        tier: :restricted,
        description:
          "Change one mark that is already on a sketch. name and id say which — the id comes from sketch_get or from the reply to sketch_add, and an id the sketch does not hold is refused as not_found rather than quietly doing nothing. Two changes exist. MOVE: dx and dy shift it by that many pixels (either may be omitted; positive dy is downward). Moving works on every kind — a stroke, a label and an image all shift by the same dx/dy. RETEXT: on a text element only, content, size and/or color replace what is there — on any other kind that is refused as not_text. Send at least one of dx, dy, content, size, color or you get no_change. YOU MAY ONLY CHANGE MARKS YOU MADE. An element authored by the operator comes back requires_confirmation: that is not an error to retry or route around, it is the operator's drawing, so say which element you wanted to change and what you wanted to do to it, and let them decide.",
        args: %{
          "name" => %{type: :string, required: true},
          "id" => %{type: :string, required: true},
          "dx" => %{type: :number, required: false},
          "dy" => %{type: :number, required: false},
          "content" => %{type: :string, required: false},
          "size" => %{type: :number, required: false},
          "color" => %{type: :string, required: false}
        }
      },
      %{
        name: "sketch_delete",
        type: :mutate,
        tier: :restricted,
        description:
          "Remove ONE mark from a sketch, by id. This deletes an element, NEVER a sketch — there is deliberately no verb here that removes a drawing, because a sketch is a file the operator owns and deleting one is their act, not yours. An id the sketch does not hold is refused as not_found rather than reported as a successful delete of nothing. YOU MAY ONLY DELETE MARKS YOU MADE: an operator-authored element comes back requires_confirmation, and the right response is to name the element and ask, not to try another route to the same removal. There is no undo behind this — the sketch file is the only copy — so on your own work, delete a false start you can describe, not a region you are guessing at; read the sketch with sketch_get first if you are not certain which id is which.",
        args: %{
          "name" => %{type: :string, required: true},
          "id" => %{type: :string, required: true}
        }
      }
    ]
end
