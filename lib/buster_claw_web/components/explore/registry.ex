defmodule BusterClawWeb.Explore.Registry do
  @moduledoc """
  The Explore tab's registries — the single source of truth every other Explore
  module reads from.

  Adding a sub-tab is **one edit in this file**: a `@features` entry, which
  renders the generic stub until its key is listed in `@built` and a panel
  module plus a dispatch line exist in `BusterClawWeb.ExplorePanel` (the two
  site tabs are the exception — they have their own `@tabs` entries).

  The rail, the Intro grid, the parent LiveView's `select_explore_tab`
  whitelist (via `BusterClawWeb.ExplorePanel.tab_keys/0`) and the panel
  dispatch all read from here, so a tab can never exist in one of them and not
  the others. That property is the reason this module is data-only: it has no
  dependency on anything, which is what lets every panel read it without a
  cycle.
  """

  @site_url "https://busterclaw.lol"
  @ntf_url "https://notesthatfloat.com"
  # Kept literal to avoid making a presentation component depend on the command
  # dispatch layer (which creates a compile cycle). The contract test derives
  # the same values from Commands.list_commands/0 and fails on drift — it is
  # `status_live_test.exs`, "the Command List tab is the atlas". Named here
  # because it took a search to find, and someone once concluded it did not
  # exist and wrote a second, weaker copy of it.
  @command_stats %{
    total: 175,
    read: 74,
    trigger: 17,
    mutate: 84,
    safe: 80,
    restricted: 95,
    gated: 20
  }

  # Feature sub-tabs: rail + tile metadata for every non-site tab. A key in
  # @built has its own tutorial panel below; the rest render the generic stub
  # (a true paragraph, a deep link, an honest "tutorial in the works" line)
  # until Phase 2 replaces them, one tab at a time.
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
    %{
      key: "phone",
      label: "BusterPhone",
      eyebrow: "The phone line",
      blurb: "An answering machine and SMS relay your agent works for you.",
      body:
        "Your agent gets its own number. Voice greets callers, records, " <>
          "transcribes, and archives messages. Trusted SMS can become Dispatch " <>
          "work; voicemail requires both a trusted number and a valid PIN before " <>
          "it is enqueued. The Phone tab is the switchboard and local archive.",
      path: "/phone",
      path_label: "Open the Phone tab"
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
      key: "cmd",
      label: "Command List",
      eyebrow: "The surface",
      blurb: "The whole command surface, one worked example at a time.",
      body:
        "Agent-addressable backend operations share one canonical command " <>
          "surface — CLI and HTTP, with operation types, caller trust tiers, " <>
          "policy flags, and audit receipts for mutations and triggers.",
      path: "/cmd-list",
      path_label: "Open the command list"
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
    }
  ]

  # Feature tabs whose tutorial panel exists — everything else stubs.
  @built ~w(models gws cmd browser)

  # {key, rail label}, in rail order. Intro leads, the two site tabs follow,
  # then the feature tabs in @features order.
  @tabs [{"intro", "Intro"}, {"site", "BusterClaw.lol"}, {"ntf", "NTF"}] ++
          Enum.map(@features, &{&1.key, &1.label})

  # Intro-grid tiles: the two site tabs, then the stubs. Grid order = rail order.
  @tiles [
           %{
             key: "site",
             label: "BusterClaw.lol",
             eyebrow: "Headquarters",
             blurb: "Where the app lives — and where your agent's number comes from."
           },
           %{
             key: "ntf",
             label: "Notes That Float",
             eyebrow: "From the same bench",
             blurb: "Creative writing and journaling in a spatial, 3D notebook."
           }
         ] ++ Enum.map(@features, &Map.take(&1, [:key, :label, :eyebrow, :blurb]))

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
