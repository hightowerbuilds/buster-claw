defmodule BusterClaw.Trading.ChatProfile do
  @moduledoc """
  Which Claude profile a Trading tab kind gets — the one place the four kinds
  map to their confinement.

  ## Why this is its own module

  This dispatch used to live in `BusterClaw.Trading`, which meant `Trading`
  referenced `ChartBuilder`, and `ChartBuilder` reaches `Portfolio`, which calls
  back into `Trading` (`Portfolio.accounts/1`). That closed a
  `Trading → ChartBuilder → Portfolio → Trading` cycle on 08-03 and undid the
  refactor roadmap's stated result that *no `lib/buster_claw` file participates
  in a cross-layer cycle*.

  A leaf breaks it the same way `AgentToolPolicy` and `AudioName` broke
  Trading↔Research and Music↔Sound: everything here points outward, nothing in
  the core points back at it, and its one caller is the LiveView.

  The mapping itself is the interesting part, so it is worth reading in one
  place: `robinhood` may read the broker and nothing else, `chartbuild` may
  search the web and read app-fetched public market data but can never see the
  broker, and a neutral `chat` is Home's full toolset — deliberately the
  broadest of the three, which is why retyping a tab *narrows* it. **None of
  them can place an order**: the write tool lives only in
  `TradingOrder.submit_cli_args/0`, behind a confirm click.

  `research` was the fourth kind until 08-03, when Chart Build absorbed the
  data-research job and its chat was deleted as redundant. Its fetchers live on
  as `BusterClaw.ChartBuilder.Fetch`.
  """

  alias BusterClaw.{ChartBuilder, SvgViewer, Trading}

  @doc "Claude options for a Trading tab kind."
  def for_kind("chartbuild"), do: ChartBuilder.chat_opts()
  def for_kind("chat"), do: [append_system_prompt: SvgViewer.guide()]
  def for_kind(_robinhood), do: Trading.chat_opts()
end
