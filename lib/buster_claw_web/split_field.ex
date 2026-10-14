defmodule BusterClawWeb.SplitField do
  @moduledoc """
  Which background fills a joined tab — decided once here, and computed the same
  way by `SplitLive` and by every pane mounted inside it, so the split and its
  children never disagree about who paints.

  Two surfaces can claim the field. A terminal background, when one is set and
  a terminal pane is present, wins: it is the louder choice and the one the
  split has always honoured. Otherwise, when the Home pane is in the join, the
  homepage background fills the whole tab — the Home pane stops drawing its own
  copy and the other panes become veils over it, the same treatment home panels
  get on the homepage. With neither, the split is plain.

  Panes learn their company through the `"split_panes"` child-session key —
  `%{"terminal" => bool, "home" => bool}` — because a nested LiveView cannot see
  its siblings any other way.
  """

  @type field :: {:terminal | :home | :none, map()}

  @doc "The field for a join whose panes are described by `panes`."
  @spec field(map() | nil, map(), map()) :: field()
  def field(panes, terminal_bg, home_bg)

  def field(nil, _terminal_bg, _home_bg), do: {:none, %{kind: :none}}

  def field(panes, terminal_bg, home_bg) when is_map(panes) do
    cond do
      truthy?(panes, "terminal") and active?(terminal_bg) -> {:terminal, terminal_bg}
      truthy?(panes, "home") and active?(home_bg) -> {:home, home_bg}
      true -> {:none, %{kind: :none}}
    end
  end

  @doc "True when the home background is the one painted across the join."
  def home_field?(panes, terminal_bg, home_bg),
    do: match?({:home, _}, field(panes, terminal_bg, home_bg))

  defp truthy?(panes, key), do: Map.get(panes, key) in [true, "true"]

  defp active?(%{kind: :none}), do: false
  defp active?(%{kind: _}), do: true
  defp active?(_), do: false
end
