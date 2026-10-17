defmodule BusterClaw.PanelTransparency do
  @moduledoc """
  How see-through the Work Area's panels are — one number, 0 to 100.

  `0` is a solid panel and `100` is no fill at all, only the blur. The default
  is the look the app shipped with: panes filled at 68% of the base colour,
  which is 32% transparency.

  Stored as **transparency** rather than opacity because that is the word the
  operator used and the word the slider shows. The CSS wants a fill percentage,
  so `fills/1` does that arithmetic in one place.

  ## Where it applies

  The Work Area sits over the background shader or image, and that is the only
  page that has one, so it is the only page that reads this. `StatusLive`
  hands the fills to `Layouts.app`, which writes them as two custom properties
  on `#app-body`:

    * `--panel-fill` — every work-area pane, and any `.ic-panel` on the home
      page (`assets/css/workbench.css`, `assets/css/app.css`);
    * `--panel-fill-menu` — the sidebar, which has always been a step more
      solid than the panes because it is navigation and has to stay legible.

  Both are computed here rather than with `calc()` inside `color-mix()`, so no
  WebKit build has to agree with Chrome about math inside a colour function.

  ## Live

  `set/1` broadcasts on `topic/0`; an open Work Area re-renders the two
  properties and every pane restyles with no other DOM change. Like the chat's
  text size, a re-select of the current value still broadcasts.
  """

  alias BusterClaw.Settings

  @setting_key "panel_transparency"
  @topic "appearance:panel_transparency"

  @default 32
  @min 0
  @max 100

  # The sidebar is this many points more solid than the panes, as it shipped
  # (68% panes, 80% sidebar).
  @menu_offset 12

  @doc "The transparency a missing or unreadable setting resolves to."
  def default, do: @default

  @doc "The accepted range, inclusive."
  def range, do: @min..@max

  @doc "PubSub topic a change is announced on."
  def topic, do: @topic

  @doc "Subscribe the calling process to changes."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc "The transparency in force, 0..100."
  def get do
    case parse(Settings.get(@setting_key)) do
      {:ok, value} when value >= @min and value <= @max -> value
      _ -> @default
    end
  end

  @doc """
  Set the transparency, announcing it on `topic/0`.

  Takes an integer or a numeric string — a slider sends a string, a command may
  send either. Returns `{:ok, value}` or `{:error, :out_of_range}` /
  `{:error, :not_a_number}`. Setting the default clears the stored row, so a
  fresh install and a reset are the same state.
  """
  def set(value) do
    with {:ok, n} <- parse(value),
         :ok <- in_range(n) do
      if n == @default,
        do: Settings.delete(@setting_key),
        else: Settings.put(@setting_key, Integer.to_string(n))

      Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:panel_transparency, n})
      {:ok, n}
    end
  end

  @doc """
  The two fill percentages the CSS reads, for a transparency `t`:
  `%{panel: 68, menu: 80}` at the default.
  """
  def fills(t) when is_integer(t) do
    panel = @max - t
    %{panel: panel, menu: min(@max, panel + @menu_offset)}
  end

  @doc "The inline style `#app-body` carries for transparency `t`."
  def style(t) when is_integer(t) do
    %{panel: panel, menu: menu} = fills(t)
    "--panel-fill: #{panel}%; --panel-fill-menu: #{menu}%;"
  end

  defp in_range(n) when n >= @min and n <= @max, do: :ok
  defp in_range(_n), do: {:error, :out_of_range}

  defp parse(n) when is_integer(n), do: {:ok, n}
  defp parse(n) when is_float(n), do: {:ok, round(n)}

  defp parse(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :not_a_number}
    end
  end

  defp parse(_value), do: {:error, :not_a_number}
end
