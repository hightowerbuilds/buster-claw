defmodule BusterClaw.Sketch.Document do
  @moduledoc """
  A sketch: an ordered list of elements and the operations on it.

  `SKETCH_ROADMAP` Phase 1. Pure — no files, no processes, no time except what an
  element stamps on itself. The store persists these; the LiveComponent renders
  them; neither one owns the rules.

  ## Order is z-order

  List order is paint order, so the last element is on top. Nothing here reorders
  implicitly: `add/2` appends, and that is the only way something gets on top.

  ## Undo is a value, not a mechanism

  Every operation returns a new document, so undo is "keep the previous one" —
  a list of past documents rather than a log of inverse operations to replay.
  For a surface whose whole state is a few hundred small maps that is the honest
  trade: bounded memory for no chance of an inverse being wrong. The bound is the
  caller's (`history_limit`), because how many steps are worth keeping is a
  product question and this module has no opinion on it.

  ## Deleting is by id, and misses are not silent

  `delete/2` returns `:error` for an id that is not here. A caller that wants to
  ignore that can, but the default is to notice — Phase 3 hands these ids to a
  model, and "the delete silently did nothing" is the failure that is impossible
  to debug from the outside.
  """

  alias BusterClaw.Sketch.Element

  @type t :: %__MODULE__{}

  defstruct id: nil,
            title: "Untitled",
            elements: [],
            created_at: nil,
            updated_at: nil

  @doc "A new empty document."
  def new(attrs \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Map.get(attrs, :id) || mint_id(),
      title: Map.get(attrs, :title, "Untitled"),
      elements: [],
      created_at: now,
      updated_at: now
    }
  end

  @doc "Append an element. It lands on top."
  def add(%__MODULE__{} = doc, %Element{} = element) do
    touch(%{doc | elements: doc.elements ++ [element]})
  end

  @doc "The element with this id, or `nil`."
  def find(%__MODULE__{} = doc, id) when is_binary(id) do
    Enum.find(doc.elements, &(&1.id == id))
  end

  def find(_doc, _id), do: nil

  @doc """
  Remove an element by id. `{:ok, doc}` or `:error` when no such element is here.
  """
  def delete(%__MODULE__{} = doc, id) when is_binary(id) do
    if find(doc, id) do
      {:ok, touch(%{doc | elements: Enum.reject(doc.elements, &(&1.id == id))})}
    else
      :error
    end
  end

  def delete(_doc, _id), do: :error

  @doc """
  Translate an element by `dx`/`dy`, in place — z-order does not change because
  moving something is not the same as raising it.
  """
  def move(%__MODULE__{} = doc, id, {dx, dy}) when is_number(dx) and is_number(dy) do
    case find(doc, id) do
      nil ->
        :error

      element ->
        {:ok, touch(%{doc | elements: replace(doc.elements, translate(element, dx, dy))})}
    end
  end

  def move(_doc, _id, _delta), do: :error

  @doc "How many elements are on this document."
  def size(%__MODULE__{elements: elements}), do: length(elements)

  @doc """
  Remove every element. Kept as an operation rather than `new/1` so the document
  keeps its id, title and creation time — clearing a sketch is not starting a
  different one, and undo has to be able to bring the elements back to *this* one.
  """
  def clear(%__MODULE__{} = doc), do: touch(%{doc | elements: []})

  # --- internals ------------------------------------------------------------

  defp translate(%Element{points: points} = element, dx, dy) when is_list(points) do
    %{element | points: Enum.map(points, fn [x, y] -> [round1(x + dx), round1(y + dy)] end)}
  end

  defp translate(element, _dx, _dy), do: element

  defp replace(elements, %Element{id: id} = updated) do
    Enum.map(elements, fn element -> if element.id == id, do: updated, else: element end)
  end

  defp round1(n), do: Float.round(n / 1, 1)

  defp touch(doc), do: %{doc | updated_at: DateTime.utc_now()}

  defp mint_id do
    "sk_" <> (9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end
end
