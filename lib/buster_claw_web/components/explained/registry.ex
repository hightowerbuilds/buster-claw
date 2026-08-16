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
  # Kept literal to avoid making a presentation component depend on the command
  # dispatch layer (which creates a compile cycle). The contract test derives
  # the same values from Commands.list_commands/0 and fails on drift — it is
  # `status_live_test.exs`, "the Command List tab is the atlas". Named here
  # because it took a search to find, and someone once concluded it did not
  # exist and wrote a second, weaker copy of it.
  # Synced 08-09 for the Studio's five capture verbs (STUDIO_ROADMAP Part V):
  # sound_gaps / sound_devices / sound_input_level are :safe reads,
  # sound_input_level_set is :restricted, and sound_record is :restricted + gated.
  # Recomputed twice on 08-15: `background_list` / `background_set`, then
  # `phone_call`. A drift test compares these against the live catalog and caught
  # both within the hour they landed — which is the only reason this block is
  # trustworthy at all.
  # Recomputed 08-16 for the contribution surface (STUDIO_ROADMAP V.0 and V.6-V.8):
  # `sound_record_save` (:restricted + gated, the recorder's write half) and the
  # four `voice_bank_*` verbs — `list` is a :safe read, `create` and `select` are
  # :restricted, `delete` is :restricted + gated.
  @command_stats %{
    total: 211,
    read: 86,
    trigger: 17,
    mutate: 108,
    safe: 89,
    restricted: 122,
    gated: 25
  }

  # Feature sub-tabs: rail + tile metadata for every non-site tab. A key in
  # @built has its own tutorial panel; anything not in it renders the generic
  # stub (a true paragraph, a deep link, an honest "tutorial in the works"
  # line). Every key is built as of 08-08 — the stub path is the on-ramp for the
  # NEXT tab, not a backlog.
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
    # screen rather than the tab it describes, because the Pockets tab is a home
    # SUB-tab with no URL of its own — the built tutorial's own button fires
    # `select_home_tab` instead, which is exact where a deep link would be a
    # near-miss. This `body` is the honest fallback if the panel ever goes away.
    %{
      key: "pockets",
      label: "Pockets",
      eyebrow: "Your own material",
      blurb: "Named folders of your own media — backgrounds, dock icons and faces live in them.",
      body:
        "A Pocket is one directory under pockets/ with a POCKET.md manifest " <>
          "saying what it holds. The background pool, the dock icons and the " <>
          "contact shaderfaces are each one. The manifest describes; it never " <>
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
      path: "/cmd-list",
      path_label: "Open the command list"
    },
    # Studio and Ramshackle are two tabs rather than one because they answer
    # different questions over the same folders. Studio is "what does this
    # machine play, and how do I change it" — a library, a routing table, four
    # editing verbs and the single gated `sound_apply`. Ramshackle is "how do I
    # build a sentence nobody said" — word indexes, alignment, a matcher, a
    # lattice. They were one tab for part of 08-09 and it was wrong: someone who
    # wants a custom chime should never have to read about dynamic time warping
    # to get one.
    %{
      key: "studio",
      label: "Studio",
      eyebrow: "Sound",
      blurb: "The chimes this machine plays — cut them, then decide what they're for.",
      body:
        "Working material in sounds/studio/, an installed library in sounds/, " <>
          "and a routing table saying which event key plays what. Trim, fade, " <>
          "normalize and join write new sources; one gated verb installs a source " <>
          "and points a key at it.",
      path: "/notify-settings",
      path_label: "Open the sound board"
    },
    %{
      key: "ramshackle",
      label: "Ramshackle",
      eyebrow: "The cut-up",
      blurb: "Sentences spliced out of recordings you already have.",
      # The one entry whose `path` is not the surface it describes, because that
      # surface does not exist: Studio → Voice is a placeholder (`Studio.Registry`'s
      # `@built` is `~w(mix)`) and the cut-up engine is reachable only through
      # commands. The tutorial opens by saying so; a deep link into an empty tab
      # would say the opposite.
      body:
        "Audio you already have — voicemails, imported files — indexed word by " <>
          "word, then cut apart and spliced into sentences nobody said. No model, " <>
          "no training, no network. The engine is complete and command-only; the " <>
          "Studio tab that will front it is not built.",
      path: "/cmd-list",
      path_label: "See every sound_ command"
    }
  ]

  # Feature tabs whose tutorial panel exists — everything else stubs. Empty of
  # stubs as of 08-08: every tab in @features has a tutorial, so `stubs/0`
  # returns [] and the `:for` that renders them is vacuous. Left in place rather
  # than deleted — the stub is what makes adding a tab a one-line edit here, and
  # a `@features` entry with no panel must still render something true.
  @built ~w(models shaders pockets phone browser cmd gws studio ramshackle)

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
      blurb: "Where the app lives — and where your agent's number comes from."
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
