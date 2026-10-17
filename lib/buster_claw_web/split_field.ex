defmodule BusterClawWeb.SplitField do
  @moduledoc """
  Which background fills a joined tab — decided once here, and computed the same
  way by `SplitLive` and by every pane mounted inside it, so the split and its
  children never disagree about who paints.

  One surface can claim the field: the app background, when it is on and a
  pane that lives on it is in the join. Two kinds of pane do — the Home pane,
  which IS the Work Area, and a terminal pane, which sits on the app background
  wherever it is (a terminal had a background of its own until 10-17, and it
  used to outrank this; it does not exist any more). The Home pane stops
  drawing its own copy and every other pane becomes a veil over the field, the
  same treatment home panels get on the homepage. With neither pane, or with
  the background off, the split is plain.

  Panes learn their company through the `"split_panes"` child-session key —
  `%{"terminal" => bool, "home" => bool}` — because a nested LiveView cannot see
  its siblings any other way.
  """

  @type field :: {:home | :none, map()}

  @doc "The field for a join whose panes are described by `panes`."
  @spec field(map() | nil, map()) :: field()
  def field(panes, home_bg)

  def field(nil, _home_bg), do: {:none, %{kind: :none}}

  def field(panes, home_bg) when is_map(panes) do
    if (truthy?(panes, "terminal") or truthy?(panes, "home")) and active?(home_bg),
      do: {:home, home_bg},
      else: {:none, %{kind: :none}}
  end

  @doc "True when the app background is the one painted across the join."
  def home_field?(panes, home_bg), do: match?({:home, _}, field(panes, home_bg))

  defp truthy?(panes, key), do: Map.get(panes, key) in [true, "true"]

  defp active?(%{kind: :none}), do: false
  defp active?(%{kind: _}), do: true
  defp active?(_), do: false
end
