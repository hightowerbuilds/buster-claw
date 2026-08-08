defmodule BusterClawWeb.BrowserPagesController do
  @moduledoc """
  The embedded browser's **Pages** index — every HTML page in
  `<workspace>/pages/`: the ones the agent has built for the user, then the
  bundled ones (Manual, Financial Informant). Reached from the hardcoded
  "Pages" button in the browser chrome. Entries open via `/ws/file` (same as
  the workspace browser) and record themselves into browser history on click.
  Dark-themed to match; loopback-only, like the rest of `/browser`.

  The markup lives in `BusterClawWeb.Browser.PagesIndex`.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Pages
  alias BusterClawWeb.Browser.PagesIndex

  def show(conn, _params) do
    # Opening the Pages index is what installs the bundled pages — they are not
    # laid down at install time (see BusterClaw.Workspace on-demand entries).
    BusterClaw.Workspace.ensure_entry("pages")

    {yours, bundled} = Enum.split_with(Pages.list(), &(not &1.bundled?))

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, PagesIndex.html(%{yours: yours, bundled: bundled}))
  end
end
