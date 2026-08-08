defmodule BusterClawWeb.Browser.PagesIndex do
  @moduledoc """
  The **Pages** index of the in-app browser: the HTML pages the agent has built
  into `<workspace>/pages/`, then the bundled ones.

  Markup only — `BusterClawWeb.BrowserPagesController` does the listing. It is
  its own module rather than living in the controller because
  `use BusterClawWeb, :controller` cannot also carry `Phoenix.Component`:
  `Plug.Conn.assign/3` and `Phoenix.Component.assign/3` collide.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Browser.Layout

  alias BusterClawWeb.Browser.Layout

  @css """
  .title { font-weight: 600; flex: 0 1 auto; overflow: hidden;
           text-overflow: ellipsis; white-space: nowrap; }
  .file { color: var(--dim); font: 12px/1.4 var(--mono);
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
          flex: 1 1 auto; }
  .when { color: var(--dim); font: 12px/1.4 var(--mono); flex: 0 0 auto; }
  """

  # `css()` rather than an assign: `html/1` is called by hand from a controller,
  # not from a HEEx template, so it has no change-tracking map and `assign/3`
  # would raise. Anything constant belongs in a function, not an assign.
  defp css, do: @css

  @doc """
  Render the Pages index to a binary.

  Takes `%{yours: [page], bundled: [page]}`. Deliberately **not** declared with
  `attr` — those only validate when a component is called from HEEx, and this is
  called by hand from a controller, so declaring them would promise a check that
  never runs.
  """
  def html(assigns) do
    ~H"""
    <.browser_page title="Pages" heading="Pages" css={css()}>
      <p :if={@yours == []} class="empty">
        Nothing here yet. Ask the agent to build you a page — any <code>.html</code>
        it saves into the workspace's <code>pages/</code>
        folder shows up in this list.
      </p>

      <ul :if={@yours != []}>
        <.row :for={page <- @yours} page={page} />
      </ul>

      <h2 :if={@bundled != []}>Built in</h2>
      <ul :if={@bundled != []}>
        <.row :for={page <- @bundled} page={page} />
      </ul>
    </.browser_page>
    """
    |> Layout.to_html()
  end

  attr :page, :map, required: true

  defp row(assigns) do
    ~H"""
    <li>
      <a data-file data-label={@page.title} href={href(@page.file)}>
        <span class="title">{@page.title}</span>
        <span class="file">{@page.file}</span>
        <span class="when">{stamp(@page.mtime)}</span>
      </a>
    </li>
    """
  end

  defp href(file), do: "/ws/file?path=" <> URI.encode_www_form("/pages/" <> file)

  # "Jul 12" — enough to scan recency; the list is already newest-first.
  defp stamp(posix) when is_integer(posix) and posix > 0 do
    posix |> DateTime.from_unix!() |> Calendar.strftime("%b %-d")
  end

  defp stamp(_unknown), do: ""
end
