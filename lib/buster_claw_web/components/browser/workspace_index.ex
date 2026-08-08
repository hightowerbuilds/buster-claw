defmodule BusterClawWeb.Browser.WorkspaceIndex do
  @moduledoc """
  The workspace file listing of the in-app browser — folders drill in, files
  open through `/ws/file`.

  Markup only; `BusterClawWeb.BrowserWorkspaceController` resolves the path and
  does the listing. Separate from the controller because
  `use BusterClawWeb, :controller` cannot also carry `Phoenix.Component`
  (`Plug.Conn.assign/3` and `Phoenix.Component.assign/3` collide).
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Browser.Layout

  alias BusterClawWeb.Browser.Layout

  @css """
  body { padding: 32px 28px; }
  h1 { margin: 6px 0 20px; font: 700 18px/1.3 var(--mono); word-break: break-all; }
  ul { margin: 0; }
  a { align-items: center; gap: 10px; padding: 10px 4px; }
  .ico { flex: 0 0 1.2em; opacity: .6; }
  """

  defp css, do: @css

  @doc """
  Render the workspace listing to a binary.

  Takes `%{dir: String.t(), entries: [entry] | :error, parent: String.t() | nil}`
  where `entries` is `:error` when the path escaped the workspace. Not declared
  with `attr`: this is called by hand from a controller, where `attr` never
  validates anything.
  """
  def html(assigns) do
    ~H"""
    <.browser_page title="Workspace" eyebrow="Workspace" css={css()}>
      <h1>{@dir}</h1>

      <p :if={@entries == :error} class="empty">That folder isn't in the workspace.</p>

      <%= if @entries != :error do %>
        <ul :if={@entries != [] or @parent}>
          <li :if={@parent}>
            <a href={"/browser/workspace?q=#{enc(@parent)}"}>
              <span class="ico">&#8617;</span>..
            </a>
          </li>
          <.entry :for={entry <- @entries} entry={entry} />
        </ul>

        <p :if={@entries == []} class="empty">Empty folder.</p>
      <% end %>
    </.browser_page>
    """
    |> Layout.to_html()
  end

  attr :entry, :map, required: true

  defp entry(%{entry: %{type: :dir}} = assigns) do
    ~H"""
    <li>
      <a href={"/browser/workspace?q=#{enc(@entry.rel <> "/")}"}>
        <span class="ico">&#128193;</span>{@entry.name}
      </a>
    </li>
    """
  end

  defp entry(assigns) do
    ~H"""
    <li>
      <a data-file data-label={@entry.rel} href={"/ws/file?path=#{enc(@entry.rel)}"}>
        <span class="ico">&#128196;</span>{@entry.name}
      </a>
    </li>
    """
  end

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
