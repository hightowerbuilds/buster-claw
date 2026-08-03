defmodule BusterClawWeb.SoundStudio.Catalog do
  @moduledoc """
  Questions about the Studio's source catalog — the grouped list of everything
  the sidebar can open.

  Extracted from `SoundStudioComponent` (CODE_QUALITY_REFACTOR Phase 3B, 08-03)
  because two consumers now ask them: the component itself and the arranger.
  Pure functions over the groups list; no assigns, no socket.
  """

  @doc "Find one source by id across every group, or `nil`."
  def find_source(_groups, nil), do: nil

  def find_source(groups, id) do
    groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.id == id))
  end

  @doc """
  The groups a clip may be added FROM: everything except mixes (a mix is a list
  of references to these, not raw material) and the music library manager,
  which is not a source at all. Groups left empty by that filter drop out
  rather than rendering a headed but empty optgroup.
  """
  def addable_groups(groups) do
    groups
    |> Enum.reject(&(&1.key == "mix"))
    |> Enum.map(fn group ->
      %{group | items: Enum.reject(group.items, &(&1.kind == :library))}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  @doc """
  A clip's playable URL, resolved from the catalog at render time — the audition
  hook fetches THIS, so what it performs is exactly what the sidebar would play.

  A vanished source resolves to `nil` and the attribute is simply absent; the
  transport skips it while Render still refuses.
  """
  def clip_src(groups, %{source: source}) do
    case find_source(groups, source) do
      %{url: url} -> url
      _ -> nil
    end
  end
end
