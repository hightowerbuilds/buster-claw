defmodule BusterClawWeb.Explained.Registry do
  @moduledoc """
  The Explained tab's registries — the single source of truth every other Explained
  module reads from.

  Adding a sub-tab is **one edit in this file**: a `@features` entry, which
  renders the generic stub until its key is listed in `@built` and a panel
  module plus a dispatch line exist in `BusterClawWeb.ExplainedPanel` (the two
  site tabs are the exception — they have their own `@tabs` entries).

  The rail, the Intro grid, the parent LiveView's `select_explained_tab`
  whitelist (via `BusterClawWeb.ExplainedPanel.tab_keys/0`) and the panel
  dispatch all read from here, so a tab can never exist in one of them and not
  the others. That property is the reason this module is data-only: it has no
  dependency on anything, which is what lets every panel read it without a
  cycle.
  """

  @site_url "https://busterclaw.lol"
  @ntf_url "https://notesthatfloat.com"
  # Kept literal so a presentation component never depends on the command
  # dispatch layer (a compile cycle). MEASURED from `Catalog.entries/0`, never
  # derived by hand, and re-measured whenever a verb lands or leaves — the
  # contract test in `status_live_test.exs` ("the Command List tab is the atlas")
  # compares these against the live catalog and is the only reason the numbers
  # are trustworthy. Last measured 10-16, after the Studio's eleven verbs left.
  @command_stats %{
    total: 166,
    read: 69,
    trigger: 17,
    mutate: 80,
    safe: 74,
    restricted: 92,
    gated: 15
  }

  # Feature sub-tabs: rail + tile metadata for every non-site tab. A key in
  # @built has its own tutorial panel; anything not in it renders the generic
  # stub (a true paragraph, a deep link, an honest "tutorial in the works"
  # line). Every key is built as of 09-05 — the stub path is the on-ramp for the
  # NEXT tab, not a backlog; the stub has never shipped.
  #
  # A tile's `blurb` is the launcher-grid one-liner and a stub's `body` is the
  # placeholder page; a built tab uses the blurb and ignores the body, so a
  # `body` here is not what the tutorial says.
  @features [
    %{
      key: "models",
      label: "Models",
      eyebrow: "The engine",
      blurb: "Which agent CLI and model run each surface — your login, your bill.",
      body:
        "Buster Claw has no AI of its own; runs use a supported agent CLI you " <>
          "installed and signed in to. Chat and unattended work support Claude, " <>
          "Codex, and OpenCode — any surface, any of the three.",
      path: "/settings",
      path_label: "Open Configuration"
    },
    %{
      key: "gws",
      label: "Gmail/GWS",
      eyebrow: "Google Workspace",
      blurb: "Connect once; the agent reads and acts on mail, calendar, files.",
      body:
        "Connect with the bundled button when this build provides it, or use " <>
          "Advanced setup with your own OAuth client. Trusted senders can enqueue " <>
          "work; other mail is still archived but does not become agent work.",
      path: "/settings",
      path_label: "Open Configuration"
    },
    %{
      key: "browser",
      label: "BrowserControl",
      eyebrow: "Hands on the web",
      blurb: "A real browser the agent drives — the tab you're looking at.",
      body:
        "Not a headless scraper: the agent reads and acts inside the same " <>
          "logged-in tab you see — browser_read, browser_click, browser_fill — " <>
          "with Agent Mode for longer errands and a payment gate that halts " <>
          "before money moves.",
      path: "/browse",
      path_label: "Open the browser"
    },
    %{
      key: "shaders",
      label: "Shaders & Backgrounds",
      eyebrow: "Ambiance",
      blurb: "The live WGSL smoke behind the homepage — and how to swap it.",
      body:
        "The homepage background is a real WGSL shader, compiled live in the " <>
          "webview. Add a valid .wgsl file to your workspace and it can appear in " <>
          "Appearance without rebuilding the app; select it there to apply it.",
      path: "/appearance",
      path_label: "Open Appearance"
    },
    # Sits next to Shaders because that is where a reader first meets the word:
    # the background pool is `pockets/backgrounds/`. Its `path` is the home
    # screen rather than the panel it describes, because the Pockets panel has
    # no URL of its own — the built tutorial's own button fires
    # `select_home_tab` instead, which is exact where a deep link would be a
    # near-miss. This `body` is the honest fallback if the panel ever goes away.
    %{
      key: "pockets",
      label: "Pockets",
      eyebrow: "Your own material",
      blurb:
        "Named folders of your own media — the background pool and the sidebar's icons live in them.",
      body:
        "A Pocket is one directory under pockets/ with a POCKET.md manifest " <>
          "saying what it holds. The background pool and the sidebar's icons " <>
          "are each one. The manifest describes; it never " <>
          "grants — so a role names a Pocket and never selects it, and a Pocket " <>
          "can be pointed at a folder elsewhere on the machine only by you.",
      path: "/",
      path_label: "Open the home screen"
    },
    %{
      key: "cmd",
      label: "Command List",
      eyebrow: "The surface",
      blurb: "The whole command surface, one worked example at a time.",
      body:
        "Agent-addressable backend operations share one canonical command " <>
          "surface — CLI and HTTP, with operation types, caller trust tiers, " <>
          "policy flags, and audit receipts for mutations and triggers.",
      # `/cmd-list` until 09-05, and it was wrong even then: that route edited the
      # terminal cheatsheet, not this atlas — `cmd.ex`'s own comment says so. The
      # route is now deleted, and the command list has no page of its own: it IS
      # this tutorial, plus `./buster-claw commands`. So the deep link goes where
      # you would actually run one.
      #
      # Only a STUB renders `path` (see `stub.ex`), and `cmd` is built — so this
      # never draws today. It is correct anyway, because the day someone unbuilds
      # this tab is not the day to discover the link 404s.
      path: "/terminal",
      path_label: "Open the terminal"
    }
  ]

  # Feature tabs whose tutorial panel exists — everything else stubs. Empty of
  # stubs as of 08-08: every tab in @features has a tutorial, so `stubs/0`
  # returns [] and the `:for` that renders them is vacuous. Left in place rather
  # than deleted — the stub is what makes adding a tab a one-line edit here, and
  # a `@features` entry with no panel must still render something true.
  @built ~w(models shaders pockets browser cmd gws)

  # The two outbound tabs. They are not features — neither teaches this app, and
  # both send you to a website — which is why they sit last rather than second
  # (operator, 08-09). Kept as their own list because they have no `body`, no
  # `path` and no tutorial module; they are not `@features` entries wearing a
  # different hat.
  @sites [
    %{
      key: "site",
      label: "BusterClaw.lol",
      eyebrow: "Headquarters",
      blurb: "The project's website, releases, and documentation."
    },
    %{
      key: "ntf",
      label: "Notes That Float",
      eyebrow: "From the same bench",
      blurb: "Creative writing and journaling in a spatial, 3D notebook."
    }
  ]

  # {key, rail label}, in rail order. Intro leads as the launcher, then the
  # feature tabs in @features order, then the two outbound site tabs.
  @tabs [{"intro", "Intro"}] ++
          Enum.map(@features, &{&1.key, &1.label}) ++
          Enum.map(@sites, &{&1.key, &1.label})

  # Intro-grid tiles. Grid order = rail order, minus Intro itself — a launcher
  # does not need a tile that reopens the launcher.
  @tiles Enum.map(@features, &Map.take(&1, [:key, :label, :eyebrow, :blurb])) ++ @sites

  @doc "The busterclaw.lol URL — headquarters, and the future number counter."
  def site_url, do: @site_url

  @doc "The notesthatfloat.com URL — the sibling project."
  def ntf_url, do: @ntf_url

  @doc "Command-surface counts quoted by the Command List tutorial."
  def command_stats, do: @command_stats

  @doc "`{key, rail label}` pairs, in rail order."
  def tabs, do: @tabs

  @doc "Intro-grid tiles, in rail order."
  def tiles, do: @tiles

  @doc "Feature tabs whose tutorial panel does not exist yet — these stub."
  def stubs, do: Enum.reject(@features, &(&1.key in @built))
end
