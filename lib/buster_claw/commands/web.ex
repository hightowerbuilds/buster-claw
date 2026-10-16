defmodule BusterClaw.Commands.Web do
  @moduledoc """
  Web-facing commands: search, browser fetch/download/screenshot, bookmarks,
  browsing history, the live tab, saved checks, and the operator's fences.
  Delegated to from `BusterClaw.Commands`.

  Since 10-16 (CODE_QUALITY_SWEEP Phase 6) this module is the facade over five
  families, one module each: `Web.Bookmarks` (`bookmark_*`, `history_*`),
  `Web.Fetch` (`web_search`, `browser_fetch`, `browser_download`), `Web.Tab`
  (the live-tab verbs), `Web.Checks` (`browser_flow`, `browser_check_*`) and
  `Web.Secrets` (`browser_secret_*`, `browser_egress_level`). It was one
  848-line module with 52 public functions and no visible interface.
  """

  alias BusterClaw.Commands.Web.{Bookmarks, Checks, Fetch, Secrets, Tab}

  defdelegate web_search(args), to: Fetch
  defdelegate browser_fetch(args), to: Fetch
  defdelegate browser_download(args), to: Fetch
  defdelegate browser_screenshot(args \\ %{}), to: Tab
  defdelegate browser_current(args \\ %{}), to: Tab
  defdelegate browser_read(args \\ %{}), to: Tab
  defdelegate browser_capture_page(args \\ %{}), to: Tab
  defdelegate browser_find_elements(args \\ %{}), to: Tab
  defdelegate browser_click(args), to: Tab
  defdelegate browser_fill(args), to: Tab
  defdelegate browser_wait(args \\ %{}), to: Tab
  defdelegate browser_extract(args \\ %{}), to: Tab
  defdelegate browser_assert(args), to: Tab
  defdelegate browser_tabs(args \\ %{}), to: Tab
  defdelegate browser_navigate(args), to: Tab
  defdelegate browser_open_tab(args), to: Tab
  defdelegate browser_control_probe(args \\ %{}), to: Tab
  defdelegate browser_flow(args), to: Checks
  defdelegate redact_flow_steps(args), to: Checks
  defdelegate browser_check_save(args), to: Checks
  defdelegate browser_check_list(args \\ %{}), to: Checks
  defdelegate browser_check_run(args), to: Checks
  defdelegate browser_egress_level(args \\ %{}), to: Secrets
  defdelegate browser_secret_put(args), to: Secrets
  defdelegate browser_secret_list(args \\ %{}), to: Secrets
  defdelegate browser_secret_delete(args), to: Secrets
  defdelegate bookmark_add(args), to: Bookmarks
  defdelegate bookmark_list(args \\ %{}), to: Bookmarks
  defdelegate bookmark_remove(args), to: Bookmarks
  defdelegate bookmark_export(args \\ %{}), to: Bookmarks
  defdelegate bookmark_import(args), to: Bookmarks
  defdelegate history_search(args), to: Bookmarks
  defdelegate history_recent(args \\ %{}), to: Bookmarks
end
