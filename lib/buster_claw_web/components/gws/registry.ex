defmodule BusterClawWeb.Gws.Registry do
  @moduledoc """
  The Google Workspace console's sub-tab registry — `{key, label, icon}` in
  display order.

  One list feeds the rail, the pane dispatch and the parent LiveView's tab
  guard. It is a separate, dependency-free module for the reason the Explained
  split found: the panes need it and the console imports the panes, so an
  accessor left on the console would put a runtime edge against a compile edge.
  """

  @console_tabs [
    {:accounts, "Accounts", "hero-user-circle"},
    {:search, "Search", "hero-magnifying-glass"},
    {:labels, "Labels", "hero-tag"},
    {:sync_mail, "Sync Mail", "hero-arrow-down-tray"},
    {:calendar, "Calendar", "hero-calendar-days"}
  ]

  @doc "The console's tabs, in display order."
  def console_tabs, do: @console_tabs

  @doc "The console's tab keys, in display order — the parent's tab guard reads this."
  def console_tab_keys, do: Enum.map(@console_tabs, &elem(&1, 0))
end
