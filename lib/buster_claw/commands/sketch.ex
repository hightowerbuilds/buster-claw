defmodule BusterClaw.Commands.Sketch do
  @moduledoc """
  The `sketch_*` command surface — the model's read **and write** access to the
  Sketch Pad (`SKETCH_ROADMAP` Phases 2 and 3). Delegated to from
  `BusterClaw.Commands`.

  ## Two reads and four writes

  `sketch_list` says what exists and `sketch_get` returns one; `sketch_create`
  makes an empty one, `sketch_add` puts a mark on it, `sketch_update` changes a
  mark and `sketch_delete` removes one. The reads shipped a phase earlier on
  purpose — the write path is built on the representation the reads proved a
  model could describe correctly, rather than on one nobody had looked at.

  ## The write half is bounded by authorship, not by tier

  `D6`, and it is the whole design: **the model may change and delete what the
  model made, and nothing else.** An operator's stroke comes back
  `{:error, :requires_confirmation}` — gated, exactly like an outbound command,
  because *"move my box to make room"* is a reasonable thing to ask for and an
  unreasonable thing to do unasked.

  The rule lives in `BusterClaw.Sketch.Authorship` and is *called* from here,
  never re-implemented. Two copies of an authorization rule is how one of them
  ends up wrong, and this is the one that decides whether a model can erase the
  operator's drawing.

  Every write therefore takes the **caller** as a second argument.
  `Commands.dispatch/3` supplies it to any command that declares arity 2. It is
  deliberately not a field in `args`: args are the untrusted half of the call,
  and a boundary whose authority is read from the same map the model fills in is
  one merge away from `"author" => "operator"` being an escalation.

  The default is `:agent` — the *least* authority any caller has, not the most.
  A direct internal call that forgets to say who it is therefore gets the
  model's boundary rather than the operator's, so the failure mode of an
  omission is an unexpected `:requires_confirmation`, never an unexpected
  deletion.

  ## What a write is checked against

  The live document, loaded fresh, every time (`D5`). An id the sketch does not
  hold is refused **by name** as `{:error, :not_found}` rather than skipped — a
  delete that silently did nothing is the failure that cannot be diagnosed from
  outside, and the model is the one holding these ids now.

  Ids are minted by `Element.new/1` and authors are stamped by
  `Authorship.author_for/1`. Neither is ever read from input: a caller-supplied
  id would let a writer address an element it does not own by guessing, and a
  caller-supplied author would let it claim one.

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

  ## Why the reads are `:safe` and the writes are not

  The reads open files under the workspace's `sketches/` directory, write
  nothing, change no setting and send nothing. Names go through `Sketch.Paths`,
  whose allowlist admits nothing shaped like a path, and asset names are checked
  the same way — there is no path building here at all.

  The four writes are `:restricted`, and `sketch_delete` is `gated` on top:
  removing a mark from someone's drawing is irreversible in the only sense that
  matters, because there is no database behind the file to recover it from.
  """

  alias BusterClaw.Sketch.{Authorship, Document, Element, Preview, Store}

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

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  @doc """
  Make a new empty sketch. Takes `name`, and an optional `title`.

  Refuses `{:error, :already_exists}` rather than truncating. `Store.save/2` is
  a blind overwrite — it has to be, since every other write goes through it —
  so the check that a create is a create belongs here, at the one verb whose
  whole meaning is "there was nothing here before".

  No caller argument: an empty document has no elements, so there is nothing for
  `D6` to own yet. Authorship is stamped per mark, not per sketch.
  """
  def sketch_create(%{"name" => name} = args) when is_binary(name) do
    with {:ok, path} <- Store.resolve(name) do
      if File.exists?(path) do
        {:error, :already_exists}
      else
        doc = Document.new(%{title: title(args, name)})

        with {:ok, _path} <- Store.save(name, doc) do
          {:ok, %{name: name, title: doc.title, count: 0}}
        end
      end
    end
  end

  def sketch_create(_args), do: {:error, :missing_name}

  @doc """
  Append an element to a sketch. Takes `name` plus the element's own fields
  (`kind`, and whatever that kind requires).

  Everything except `name` goes to `Element.new/1`, which is the validation
  boundary — this function has no field rules of its own, so there is no second
  copy to drift. Two fields are taken *away* from the caller first: `id`, which
  `Element.new/1` mints, and `author`, which `Authorship.author_for/1` stamps
  from the caller. Neither is ever accepted from input; see the moduledoc.
  """
  def sketch_add(args, caller \\ :agent)

  def sketch_add(%{"name" => name} = args, caller) when is_binary(name) do
    with {:ok, doc} <- Store.load(name),
         {:ok, element} <- Element.new(element_attrs(args, caller)),
         updated = Document.add(doc, element),
         {:ok, _path} <- Store.save(name, updated) do
      {:ok,
       %{
         name: name,
         id: element.id,
         kind: Atom.to_string(element.kind),
         author: Atom.to_string(element.author),
         count: Document.size(updated)
       }}
    end
  end

  def sketch_add(_args, _caller), do: {:error, :missing_name}

  @doc """
  Change one element. Takes `name` and `id`, plus what to change.

  Two changes exist, deliberately: a translation (`dx`/`dy`) and, for a text
  label, its `content`, `size` or `color`. There is no general field patcher —
  one would mean accepting arbitrary keys against an element whose validation is
  per-kind, and the shapes a model actually needs are "move that" and "fix that
  label".

  `Authorship.check/3` runs **first**, against the document as it is on disk. An
  operator's mark is refused before anything is computed, and an unknown id is
  refused by name.
  """
  def sketch_update(args, caller \\ :agent)

  def sketch_update(%{"name" => name, "id" => id} = args, caller)
      when is_binary(name) and is_binary(id) do
    with {:ok, doc} <- Store.load(name),
         :ok <- Authorship.check(doc, id, caller),
         {:ok, updated} <- change(doc, id, args),
         {:ok, _path} <- Store.save(name, updated) do
      {:ok, %{name: name, id: id, count: Document.size(updated)}}
    end
  end

  def sketch_update(_args, _caller), do: {:error, :missing_name_or_id}

  @doc """
  Remove one element from a sketch. Takes `name` and `id`.

  This deletes a **mark, not a drawing**. There is deliberately no verb here
  that removes a whole sketch: a sketch is a file the operator owns (`D9`), and
  deleting one is deleting a file — an operator act, the same split Pockets
  draws around mounting.
  """
  def sketch_delete(args, caller \\ :agent)

  def sketch_delete(%{"name" => name, "id" => id}, caller)
      when is_binary(name) and is_binary(id) do
    with {:ok, doc} <- Store.load(name),
         :ok <- Authorship.check(doc, id, caller),
         {:ok, updated} <- drop(doc, id),
         {:ok, _path} <- Store.save(name, updated) do
      {:ok, %{name: name, id: id, deleted: true, count: Document.size(updated)}}
    end
  end

  def sketch_delete(_args, _caller), do: {:error, :missing_name_or_id}

  # --- writing internals ----------------------------------------------------

  defp title(args, name) do
    case Map.get(args, "title") do
      title when is_binary(title) ->
        case String.trim(title) do
          "" -> name
          trimmed -> trimmed
        end

      _other ->
        name
    end
  end

  # `name` is ours, not the element's. `id` and `author` are dropped rather than
  # ignored: `Element.new/1` already discards an `id`, but dropping it here says
  # so at the boundary where a reader is asking the question, and `author` has
  # no such protection — `Element.new/1` will honour one, which is exactly why
  # it must never reach it from input.
  defp element_attrs(args, caller) do
    args
    |> Map.drop(["name", "id", "author"])
    |> Map.put("author", Authorship.author_for(caller))
  end

  defp change(doc, id, args) do
    with {:ok, delta} <- delta(args) do
      case {delta, text_changes(args)} do
        {nil, changes} when map_size(changes) == 0 ->
          {:error, :no_change}

        {delta, changes} ->
          with {:ok, doc} <- translate(doc, id, delta), do: retext(doc, id, changes)
      end
    end
  end

  # A missing key means "leave it"; a key that is present and not a number is a
  # mistake worth naming. Supplying only one axis is fine — the other is zero.
  defp delta(args) do
    case {Map.get(args, "dx"), Map.get(args, "dy")} do
      {nil, nil} ->
        {:ok, nil}

      {dx, dy} when (is_number(dx) or is_nil(dx)) and (is_number(dy) or is_nil(dy)) ->
        {:ok, {dx || 0, dy || 0}}

      _other ->
        {:error, :bad_delta}
    end
  end

  defp translate(doc, _id, nil), do: {:ok, doc}

  # `Document.move/3` translates a stroke's `points` and returns every other kind
  # **unchanged, with `{:ok, doc}`** — a text label or an image would be told it
  # moved and would not have. That is precisely the silent no-op `D5` refuses, so
  # a move that did not move is reported by name instead of passed on as success.
  # The check goes quiet on its own the day `Document.move/3` learns `x`/`y`.
  defp translate(doc, id, {dx, dy}) do
    # `Document.move/3` answers all three cases itself now. This used to compare
    # the element before and after to catch a move that silently did nothing,
    # because `move/3` translated `points` only and returned `{:ok, doc}` for
    # every other kind — a write that reported success and did nothing, which is
    # the failure `D5` is about. The fix belonged one layer down, at the place
    # that knows how each kind stores its position.
    case Document.move(doc, id, {dx, dy}) do
      :error -> {:error, :not_found}
      {:ok, moved} -> {:ok, moved}
    end
  end

  defp text_changes(args) do
    args |> Map.take(["content", "size", "color"]) |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp retext(doc, _id, changes) when map_size(changes) == 0, do: {:ok, doc}

  defp retext(doc, id, changes) do
    case Document.find(doc, id) do
      %Element{kind: :text} = element ->
        rehydrate(doc, element, changes)

      %Element{} ->
        {:error, :not_text}

      nil ->
        {:error, :not_found}
    end
  end

  # The edited label goes back through `Element.rehydrate/1` rather than being
  # patched in place. That is the point: a new `content` or `color` from a model
  # crosses the same boundary a fresh one does — the control-character strip, the
  # length cap, the six-hex-digit colour allowlist, the closed set of sizes —
  # with no second copy of any of those rules living here. Rehydration keeps the
  # id, the author and the creation time, which is what makes this an edit.
  defp rehydrate(doc, element, changes) do
    attrs = element |> text_attrs() |> Map.merge(changes)

    with {:ok, updated} <- Element.rehydrate(attrs) do
      {:ok, put_element(doc, updated)}
    end
  end

  defp text_attrs(%Element{} = el) do
    %{
      "id" => el.id,
      "kind" => "text",
      "author" => el.author,
      "created_at" => el.created_at,
      "content" => el.content,
      "color" => el.color,
      "size" => el.size,
      "x" => el.x,
      "y" => el.y
    }
  end

  # `Document` has `add`, `delete` and `move` but no `update`, and delete-then-add
  # would be wrong rather than merely clumsy: `add/2` appends, so recolouring a
  # label would silently raise it above everything drawn after it. List order is
  # z-order and an edit is not a raise, so the element is replaced where it sits.
  # The cost is one copy of the private `touch/1` — worth it against losing the
  # ordering invariant. A `Document.update/3` would retire this.
  defp put_element(doc, %Element{id: id} = element) do
    elements = Enum.map(doc.elements, fn el -> if el.id == id, do: element, else: el end)

    %{doc | elements: elements, updated_at: DateTime.utc_now()}
  end

  defp drop(doc, id) do
    case Document.delete(doc, id) do
      {:ok, updated} -> {:ok, updated}
      :error -> {:error, :not_found}
    end
  end

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

  # Added with Phase 3's write half, and not before it was needed: `:text` was a
  # kind `Element` accepted and nothing could create, so this clause was missing
  # and `sketch_get` would have raised on the first label `sketch_add` wrote. The
  # content is returned in full — unlike a stroke's coordinates it IS the thing
  # the model is reasoning about, and it is capped at 2,000 characters upstream.
  #
  # `at` rather than `bounds`, and the difference is not cosmetic: a label is
  # sized by the renderer measuring its own glyphs, so nothing here knows its
  # width. Reporting `w: 0` would be a measurement, and a wrong one.
  defp element(%{kind: :text} = el) do
    %{
      id: el.id,
      kind: "text",
      author: Atom.to_string(el.author),
      content: el.content,
      color: el.color,
      size: el.size,
      at: %{x: el.x, y: el.y}
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
