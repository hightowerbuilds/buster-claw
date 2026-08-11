defmodule BusterClawWeb.Phone.Registry do
  @moduledoc """
  The Phone tab's sub-tab registry — the single source of truth for every module
  that renders or guards a Phone sub-tab.

  The rail in `BusterClawWeb.PhoneComponent`, that component's
  `select_phone_tab` whitelist and its panel dispatch all read from here, so a
  sub-tab can never exist in one of them and not the others. That property is
  the reason this module is data-only: it depends on nothing, which is what lets
  the component read it at **compile time** — a `when tab in ...` guard cannot
  call a remote function, and reading it into a module attribute is what makes
  the rail and the guard the same list rather than two that agree today.

  Copied from `BusterClawWeb.Studio.Registry`, which copied
  `BusterClawWeb.Explained.Registry`, which solved this first.

  ## Why this is not a style preference

  On 08-08 the homepage's Phone tab shipped as a rail button the server then
  **refused**: the rail offered it, `select_home_tab`'s guard had never heard of
  it, and the click raised. They were two literals that drifted.
  `BusterClawWeb.StatusLive`'s `@home_tabs` carries the note. This registry is
  that lesson applied one level down, before the same split can happen inside
  the Phone tab itself.

  ## Why Messages and Contacts are two tabs

  They were one surface with three panels, and the two halves want different
  room: the log wants width and the contact face wants height. Splitting them
  also gives the contact face card the whole panel instead of the bottom third.

  There is no `@built` list here, unlike Studio's. Both surfaces exist — they
  are the panels the tab already rendered — so a placeholder arm would be an
  unreachable branch shipped for a hypothetical third tab.
  """

  # The sub-tabs, in rail order. `blurb` is the rail button's `title`.
  @tabs [
    %{
      key: "messages",
      label: "Messages",
      blurb: "The log, the keypad, and whatever is playing: voicemail, texts, calls."
    },
    %{
      key: "contacts",
      label: "Contacts",
      blurb: "Who the machine knows, their shaderface, and whether they reach the agent."
    }
  ]

  @doc "The sub-tabs, in rail order."
  def tabs, do: @tabs

  @doc """
  Sub-tab keys, in rail order — the `select_phone_tab` whitelist.

  Read into a module attribute by the component so the guard is generated from
  the same list the rail renders. See the moduledoc.
  """
  def tab_keys, do: Enum.map(@tabs, & &1.key)
end
