defmodule BusterClawWeb.Settings.Registry do
  @moduledoc """
  The Configuration page's sub-tab registry — the single source of truth the
  rail, the parent's `select_settings_tab` whitelist and the dispatch in
  `SettingsLive.render/1` all read.

  Copied from `BusterClawWeb.Studio.Registry`, which copied
  `BusterClawWeb.Explained.Registry`, which solved this first. The property
  worth copying is that a sub-tab cannot exist in the rail and not in the guard:
  all three read `tabs/0`, and `resolve/1` is the only thing that turns a
  clicked string into a key. That is the same shape as the GWS console rail
  below it, which was two hand-written lists until 08-08.

  This module is data-only on purpose: it depends on nothing, which is what lets
  the rail component, the LiveView and (later) any extracted sub-tab module all
  read it without a compile cycle.

  ## Why Models leads

  Configuration is four unrelated features, and only one of them has to be right
  for the app to do anything at all: without an agent harness there is nothing
  to run. Google Workspace, the profile and the credentials are all additions to
  a working app. The 08-15 DMG review found first launch showing a fully
  disabled model picker with no explanation, which is the moment this ordering
  is for.

  ## Adding a sub-tab

  One entry here, plus one `:if` branch in `SettingsLive.render/1`. There is no
  placeholder path — unlike Explained and Studio, every tab here is a section
  that already existed on the long page, so a key with no branch renders an
  empty tab rather than an honest stub. If this page ever grows a tab before its
  section exists, copy Studio's `@built` + placeholder.
  """

  # The sub-tabs, in rail order. `blurb` is the rail button's `title` — the one
  # line saying what the tab holds.
  @tabs [
    %{
      key: "models",
      label: "Agent & models",
      blurb: "Which agent CLI runs each surface, and on which model."
    },
    %{
      key: "google",
      label: "Google Workspace",
      blurb: "Connect Google accounts, check their health, pull mail and events."
    },
    %{
      key: "profile",
      label: "Profile",
      blurb: "Your name and organization, and how far setup got."
    },
    %{
      key: "credentials",
      label: "Credentials",
      blurb: "Service keys, stored sign-ins, and the recovery key."
    }
  ]

  @default "models"

  @doc "The sub-tabs, in rail order."
  def tabs, do: @tabs

  @doc "Sub-tab keys, in rail order — the rail's buttons and the guard's whitelist."
  def keys, do: Enum.map(@tabs, & &1.key)

  @doc "The tab an operator lands on with no tab named."
  def default, do: @default

  @doc """
  Resolve a tab key that came from outside — a rail click or a `?tab=` link.

  Anything unrecognised falls back to the default rather than assigning a key no
  branch renders, which would leave the page blank below the rail.
  """
  def resolve(tab) when is_binary(tab), do: if(tab in keys(), do: tab, else: @default)
  def resolve(_tab), do: @default
end
