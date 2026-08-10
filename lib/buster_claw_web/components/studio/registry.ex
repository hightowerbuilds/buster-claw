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

  ## The Voice tab currently holds two different activities

  `Voice` is voice training and ramshackle audio creation, and that is really
  *two* things: **recording** (STUDIO_ROADMAP V.6–V.8) and **browsing,
  auditioning and correcting a dictionary** of what was captured (VI.1–VI.3).
  The roadmap says as much, and they may well want to be two tabs rather than
  one. They share a tab today because neither is built.

  **Splitting them later is one edit here** — which is the whole reason for
  copying Explained's data-only registry rather than hand-rolling a rail in the
  panel.
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
      label: "Voice",
      blurb: "Voice training and ramshackle audio creation.",
      eyebrow: "Nothing here yet",
      body:
        "Voice training and ramshackle audio creation land on this tab: taking " <>
          "recordings straight into the workspace, and a dictionary of what was " <>
          "captured to browse, audition, and correct. Neither is built — this is " <>
          "the frame they land in, shipped first so the tab that holds them is " <>
          "not also the thing being debugged."
    }
  ]

  # Sub-tabs whose surface exists. Anything else renders the placeholder, which
  # is what makes adding a tab a one-line edit above rather than a rail button
  # that leads nowhere.
  @built ~w(mix)

  @doc "The sub-tabs, in rail order."
  def tabs, do: @tabs

  @doc "Sub-tabs whose surface does not exist yet — these render a placeholder."
  def placeholders, do: Enum.reject(@tabs, &(&1.key in @built))
end
