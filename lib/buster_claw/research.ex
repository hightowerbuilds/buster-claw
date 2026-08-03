defmodule BusterClaw.Research do
  @moduledoc """
  The Trading page's Research tab: public market data, and a chat that cannot
  see the broker.

  This is the deliberate counterweight to the Robinhood tab. That surface can
  read your positions and (behind a confirm click) place an order; this one
  cannot do either, by construction — its runs carry no Robinhood MCP config at
  all, so there is no broker tool to allow or deny. What it can do is look up
  a symbol anyone could look up.

  ## Where the numbers come from

  Everything is fetched **app-side** through `BusterClaw.Finance` and rendered
  from the returned struct, never typed by a model:

    * quote — Finnhub free tier, US equities, typically ~15 minutes delayed
    * fundamentals and filings — SEC EDGAR, free and keyless
    * symbol search — EDGAR's company-ticker file

  That split is the lesson of 07-28 applied ahead of time rather than after: a
  language model is good at deciding *which* symbol you meant and bad at
  transcribing what it is worth. So the chat picks the question and the panel
  answers it.

  Every figure carries its own `source` and `as_of` — `Finance` guarantees that
  by construction, and the panel is required to render both.
  """

  alias BusterClaw.DataState
  alias BusterClaw.Finance

  @system_prompt """
  You are a public-market research assistant inside Buster Claw.

  What you can see:
  - Public market data only: quotes, SEC filings, XBRL fundamentals, company news.
  - You have NO access to the operator's brokerage accounts, positions, balances,
    or order history. Not "you may not" — there is no tool. If asked about their
    holdings, say plainly that the Robinhood tab is where account data lives, and
    that this tab cannot see it.
  - You cannot place, amend, or cancel an order, and nothing you write here can.

  How to answer:
  - The panel beside this chat shows the live quote, fundamentals and recent
    filings for whichever symbol is in focus. Prefer to reference what is ALREADY
    on screen rather than restating numbers — and when you do state one, say
    where it came from and how old it is.
  - Never invent a price, a ratio, a filing date, or an earnings figure. If you
    do not have the number, say so and name the symbol you would need looked up.
  - Free-tier quotes are delayed roughly 15 minutes. Never describe one as live,
    real-time, or current-to-the-second.
  - Distinguish what a filing SAYS from what it means. Quote the former; label
    the latter as your reading.
  - You are not a financial adviser and this is not advice. Say so when asked
    what to buy, then give the analysis anyway — the operator can decide.
  """

  @doc """
  `Chat.ensure_started/2` options for a Research conversation.

  No `--mcp-config` and no Robinhood tools: this run has no broker surface to
  confine. The built-in denials mirror the trading side so a research chat can't
  reach the shell or the filesystem either.
  """
  def chat_opts do
    [
      append_system_prompt: @system_prompt,
      permission_mode: "dontAsk",
      extra_cli_args: [
        "--disallowedTools",
        Enum.join(BusterClaw.AgentToolPolicy.denied_builtins(), ",")
      ]
    ]
  end

  @doc "The Research system prompt. Exposed for tests."
  def system_prompt, do: @system_prompt

  @doc """
  Everything the Research panel renders for one symbol.

  Each dataset is an independent `DataState` because they fail independently:
  EDGAR is keyless and nearly always answers, Finnhub is key-gated and rate
  limited, and a symbol EDGAR knows may have no Finnhub quote at all. One of
  them being unavailable must not blank the other two.
  """
  def load(symbol, opts \\ []) when is_binary(symbol) do
    # The same seam the Trading fetchers use: without it a LiveView test of the
    # panel makes three real HTTP calls to the SEC and Finnhub.
    case Application.get_env(:buster_claw, :research_loader) do
      fun when is_function(fun, 1) -> fun.(normalize(symbol))
      _default -> fetch(symbol, opts)
    end
  end

  defp fetch(symbol, opts) do
    symbol = normalize(symbol)

    %{
      symbol: symbol,
      quote: to_state(Finance.quote(symbol, opts), :finnhub),
      fundamentals: to_state(Finance.fundamentals(symbol, opts), :edgar),
      filings: to_state(Finance.filings(symbol, opts), :edgar)
    }
  end

  @doc "Typeahead over EDGAR's company-ticker file. `[%{symbol, name}]`."
  def search(query, opts \\ []) when is_binary(query) do
    case query |> String.trim() |> Finance.search(opts) do
      {:ok, results} -> Enum.take(results, 8)
      _error -> []
    end
  end

  @doc "An empty panel state, for a tab with no symbol chosen yet."
  def blank do
    %{
      symbol: nil,
      quote: DataState.unavailable(:no_symbol, source: :finnhub),
      fundamentals: DataState.unavailable(:no_symbol, source: :edgar),
      filings: DataState.unavailable(:no_symbol, source: :edgar)
    }
  end

  @doc "A symbol as EDGAR and Finnhub both want it: upper case, no padding."
  def normalize(symbol), do: symbol |> String.trim() |> String.upcase()

  # `:not_configured` is its own reason on purpose: "we never asked" (no Finnhub
  # key) reads differently to the operator than "we asked and the symbol has no
  # quote", and the panel words them differently.
  defp to_state({:ok, [] = empty}, source),
    do: DataState.confirmed_empty(data: empty, as_of: DateTime.utc_now(), source: source)

  defp to_state({:ok, data}, source),
    do: DataState.fresh(data, as_of: as_of_of(data), source: source)

  defp to_state({:error, reason}, source), do: DataState.unavailable(reason, source: source)

  defp as_of_of(%{as_of: %DateTime{} = at}), do: at
  defp as_of_of([%{as_of: %DateTime{} = at} | _rest]), do: at
  defp as_of_of(_data), do: DateTime.utc_now()
end
