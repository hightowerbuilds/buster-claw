defmodule BusterClaw.ChartBuilder.Fetch do
  @moduledoc """
  Chart Build's data-research layer: public market data, fetched **app-side**.

  Moved here 08-03 from `BusterClaw.Research` when the Research chat was deleted
  and Chart Build became the app's one data-research surface
  (`daily-growth/roadmaps/CHART_BUILD_WEB_DATA_ROADMAP.md` Phase 0). The chat half
  of that module — its system prompt and tool confinement — is gone; this half is
  the part worth keeping, and it is now load-bearing rather than incidental.

  ## Why this exists at all

  Chart Build's model may search the web, but it may **not** plot a number it
  read there. Everything it draws comes through here: fetched by us, from a named
  source, with an `as_of`, never typed by a model. That split is the 07-28 lesson
  applied rather than relearned — a language model is good at deciding *which*
  symbol you meant and bad at transcribing what it is worth. So the chat picks
  the question and this module answers it.

  Nothing here reaches the broker. There is no Robinhood tool in this path, no
  account, no position, no order — only what anyone could look up:

    * quote — Finnhub free tier, US equities, typically ~15 minutes delayed
    * fundamentals and filings — SEC EDGAR, free and keyless
    * symbol search — EDGAR's company-ticker file

  Every figure carries its own `source` and `as_of`. `BusterClaw.Finance`
  guarantees that by construction, and every surface rendering one is required to
  show both.
  """

  alias BusterClaw.DataState
  alias BusterClaw.Finance

  @doc """
  Everything the Chart Build lookup panel renders for one symbol.

  Each dataset is an independent `DataState` because they fail independently:
  EDGAR is keyless and nearly always answers, Finnhub is key-gated and rate
  limited, and a symbol EDGAR knows may have no Finnhub quote at all. One of
  them being unavailable must not blank the other two.
  """
  def load(symbol, opts \\ []) when is_binary(symbol) do
    # The same seam the Trading fetchers use: without it a LiveView test of the
    # panel makes three real HTTP calls to the SEC and Finnhub.
    case Application.get_env(:buster_claw, :chart_builder_loader) do
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
