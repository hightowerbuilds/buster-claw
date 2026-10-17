defmodule BusterClawWeb.Settings.Registry do
  @moduledoc """
  The `SettingsLive` section registry — the single source of truth the
  `?tab=` whitelist and the dispatch in `SettingsLive.render/1` both read.
  The Settings tab bar (`SettingsTabs`) carries one top-level tab per key
  since 10-17, when the "Configuration" tab and its in-page rail went.

  Copied from `BusterClawWeb.Explained.Registry`, which solved this first. The property
  worth copying is that a section cannot exist in the dispatch and not in the
  guard: both read `keys/0`, and `resolve/1` is the only thing that turns a
  `?tab=` string into a key. That is the same shape as the GWS console rail,
  which was two hand-written lists until 08-08.

  This module is data-only on purpose: it depends on nothing, which is what lets
  the LiveView and any extracted section module read it without a compile
  cycle.

  ## Why Models is the default

  Only one of these sections has to be right for the app to do anything at
  all: without an agent harness there is nothing to run. Google Workspace and
  the credentials are additions to a working app. The 08-15 DMG review found
  first launch showing a fully disabled model picker with no explanation, which
  is the moment this default is for. (A Profile section — name, organization,
  setup progress — and an About section sat here until 10-17; About is a panel
  on Security now, and the setup re-run with it.)

  ## Adding a section

  One entry here, one tab in `SettingsTabs`, plus one `:if` branch in
  `SettingsLive.render/1`. There is no placeholder path — a key with no branch
  renders an empty page rather than an honest stub.
  """

  # The sections, in the tab bar's order. `blurb` is the one line saying what
  # the section holds.
  @tabs [
    %{
      key: "models",
      label: "Agents & models",
      blurb: "Which agent CLI runs each surface, and on which model."
    },
    %{
      key: "google",
      label: "Google Workspace",
      blurb: "Connect Google accounts, check their health, pull mail and events."
    },
    %{
      key: "credentials",
      label: "Credentials",
      blurb: "Stored sign-ins and the recovery key."
    },
    %{
      key: "speech",
      label: "Speech",
      blurb: "Choose the Mac voice and speed for reading chat replies aloud."
    }
  ]

  @default "models"

  @doc "The sections, in tab-bar order."
  def tabs, do: @tabs

  @doc "Section keys, in tab-bar order — the guard's whitelist."
  def keys, do: Enum.map(@tabs, & &1.key)

  @doc "The tab an operator lands on with no tab named."
  def default, do: @default

  @doc "A section's tab label, for the page title."
  def label(key), do: Enum.find_value(@tabs, key, &(&1.key == key && &1.label))

  @doc """
  Resolve a section key that came from outside — a `?tab=` link.

  Anything unrecognised falls back to the default rather than assigning a key no
  branch renders, which would leave the page blank below the tab bar.
  """
  def resolve(tab) when is_binary(tab), do: if(tab in keys(), do: tab, else: @default)
  def resolve(_tab), do: @default
end
