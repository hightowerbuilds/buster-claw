defmodule BusterClawWeb.Studio.Registry do
  @moduledoc """
  The Studio tab's sub-tab registry — the single source of truth every module
  that renders a Studio sub-tab reads from.

  The rail, the parent LiveView's `select_studio_tab` whitelist (via
  `BusterClawWeb.StudioPanel.tab_keys/0`) and the panel dispatch all read from
  here, so a sub-tab can never exist in one of them and not the others. That
  property is the reason this module is data-only: it depends on nothing, which
  is what lets every one of them read it without a compile cycle.

  Copied from `BusterClawWeb.Explained.Registry`, which solved this first.

  Adding a sub-tab is **one edit in this file**: a `@tabs` entry, which renders
  the honest placeholder until its key is listed in `@built` and a dispatch line
  exists in `BusterClawWeb.StudioPanel`. A new rail button is therefore never a
  dead one.

  ## Voice split into two tabs on 08-16, and merged back the same day

  This module used to predict a split — recording (STUDIO_ROADMAP V.6–V.8) away
  from browsing a dictionary (VI.1–VI.3) — and promised it would cost one edit
  here. When the recorder was built, the split happened and the promise held
  exactly: one `@tabs` entry, one word in `@built`.

  **Then the operator looked at it and merged them back**, and that is the more
  useful half of the story. Two rail buttons described the *implementation*
  (a dictionary module and a recorder module) rather than the **activity**, which
  is one thing: working on your voice. Browsing words, hearing them, building a
  sentence and recording a missing word are steps of a single loop, and a rail
  that makes you leave the tab to close that loop is a rail in the way.

  So `Voice Library` is one tab with a **sidebar** — the loop is navigated
  inside it, not above it. The registry cost of merging back was the same one
  entry, in the other direction, which is the actual thing worth recording: a
  data-only registry made the reorganisation reversible, and the reversal is
  what proved it rather than the split.
  """

  # The sub-tabs, in rail order.
  #
  # `blurb` is the rail button's `title` — the one line that says what the tab
  # is for. `eyebrow` and `body` are the placeholder page's, so they belong only
  # to a tab that is not in @built yet; a built tab's surface writes its own
  # copy and would ignore them.
  @tabs [
    %{
      key: "mix",
      label: "Mix",
      blurb: "Cut and arrange: sources, trims, clips, and saved mixes."
    },
    %{
      key: "voice",
      label: "Voice Library",
      blurb: "Ramshackle: your words, the sentences they make, and the mic that adds more."
    }
  ]

  # Sub-tabs whose surface exists. Anything else renders the placeholder, which
  # is what makes adding a tab a one-line edit above rather than a rail button
  # that leads nowhere.
  # `voice` joined 08-14 with VI.1's vocabulary and sentence-check panes. Its
  # placeholder copy went with it: a built tab writes its own, and leaving the
  # old `eyebrow`/`body` here would have left the tab's honest "nothing here
  # yet" text sitting in the registry to be rendered again by mistake.
  @built ~w(mix voice)

  @doc "The sub-tabs, in rail order."
  def tabs, do: @tabs

  @doc "Sub-tabs whose surface does not exist yet — these render a placeholder."
  def placeholders, do: Enum.reject(@tabs, &(&1.key in @built))
end
