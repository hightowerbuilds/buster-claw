defmodule BusterClaw.Watchlist do
  @moduledoc """
  Named lists of symbols the operator wants the market cache to hold.

  Until now a symbol entered the cache by being **held** and by nothing else —
  `MarketData.refresh/1`'s prompt opens *"Collect market data for the operator's
  holdings"*. There was no way to say "I care about NVDA" short of buying some.
  This is that way.

  ## Lists, plural

  The operator asked for watchlist**s**, so the shape is named lists rather than
  one flat set. A symbol may appear in several; `symbols/0` is the union, which
  is what any fetch actually wants.

  ## What this does NOT do

  **It does not fetch anything.** Adding a symbol here records an intention; the
  bars arrive when something decides to spend a run on them. That separation is
  deliberate — a deep backfill costs **~$0.57 of model time** (measured 08-04),
  so "add to a list" and "spend money" must not be the same gesture.

  It also never deletes bars. Removing a symbol stops future fetches; cached
  history is expensive to reacquire and is kept.

  ## Where it lives

  `Settings`, not a workspace file — a seeded file could never be corrected on an
  install that already had one (`LAUNCH_ROADMAP` **V.8**).

  ## Leaf, deliberately

  Depends on `Settings` and nothing else. `MarketData` may read this; this reads
  nothing back, so no cycle is possible.
  """

  alias BusterClaw.Settings

  @settings_key "watchlists"

  # A ticker as the brokers spell them: letters, with `.` and `-` for class
  # shares and some ETFs (BRK.B, RDS-A). Deliberately NOT a strict exchange
  # validation — this app cannot enumerate every valid symbol, and refusing a
  # real one is worse than accepting a typo that simply never returns bars.
  @symbol_pattern ~r/^[A-Z][A-Z0-9.\-]{0,9}$/
  @max_name_length 40

  @doc "Every list, name => symbols. Names sorted, symbols in insertion order."
  def all do
    with raw when is_binary(raw) <- Settings.get(@settings_key),
         {:ok, %{} = decoded} <- Jason.decode(raw) do
      for {name, symbols} <- decoded,
          is_binary(name),
          is_list(symbols),
          into: %{},
          do: {name, Enum.filter(symbols, &is_binary/1)}
    else
      _ -> %{}
    end
  end

  @doc "List names, sorted."
  def names, do: all() |> Map.keys() |> Enum.sort()

  @doc "The symbols in one list, or `[]` when it does not exist."
  def list(name) when is_binary(name), do: Map.get(all(), name, [])

  @doc """
  Every symbol across every list, deduplicated and sorted.

  This is what a fetch wants: the operator's lists are for organising attention,
  but a symbol is fetched once no matter how many lists it appears in.
  """
  def symbols, do: all() |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()

  @doc "True when `symbol` appears in any list."
  def watched?(symbol) when is_binary(symbol), do: normalize(symbol) in symbols()
  def watched?(_symbol), do: false

  @doc """
  Create an empty list. Refuses a blank or over-long name, and refuses to
  clobber one that exists — renaming and merging are not this function's job.
  """
  def create(name) when is_binary(name) do
    trimmed = String.trim(name)
    lists = all()

    cond do
      trimmed == "" -> {:error, :blank_name}
      String.length(trimmed) > @max_name_length -> {:error, :name_too_long}
      Map.has_key?(lists, trimmed) -> {:error, {:exists, trimmed}}
      true -> write(Map.put(lists, trimmed, []))
    end
  end

  def create(_name), do: {:error, :blank_name}

  @doc "Delete a list. Symbols in it stop being watched; their bars are untouched."
  def delete(name) when is_binary(name) do
    lists = all()

    if Map.has_key?(lists, name),
      do: write(Map.delete(lists, name)),
      else: {:error, {:no_such_list, name}}
  end

  @doc """
  Add `symbol` to `name`. Upper-cases and trims first, so `nvda ` and `NVDA` are
  the same entry rather than two.
  """
  def add(name, symbol) when is_binary(name) and is_binary(symbol) do
    lists = all()
    sym = normalize(symbol)

    cond do
      not Map.has_key?(lists, name) -> {:error, {:no_such_list, name}}
      not valid_symbol?(sym) -> {:error, {:bad_symbol, symbol}}
      sym in Map.fetch!(lists, name) -> {:ok, lists}
      true -> write(Map.update!(lists, name, &(&1 ++ [sym])))
    end
  end

  def add(_name, _symbol), do: {:error, :bad_symbol}

  @doc "Remove `symbol` from `name`. Never touches cached bars."
  def remove(name, symbol) when is_binary(name) and is_binary(symbol) do
    lists = all()
    sym = normalize(symbol)

    if Map.has_key?(lists, name),
      do: write(Map.update!(lists, name, &List.delete(&1, sym))),
      else: {:error, {:no_such_list, name}}
  end

  @doc "True if `symbol` is shaped like a ticker. See `@symbol_pattern`."
  def valid_symbol?(symbol) when is_binary(symbol), do: Regex.match?(@symbol_pattern, symbol)
  def valid_symbol?(_symbol), do: false

  @doc "Upper-case and trim, the one normalization applied everywhere."
  def normalize(symbol) when is_binary(symbol), do: symbol |> String.trim() |> String.upcase()

  defp write(lists) do
    Settings.put(@settings_key, Jason.encode!(lists))
    {:ok, lists}
  end
end
