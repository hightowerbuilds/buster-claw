defmodule BusterClaw.FTS do
  @moduledoc """
  The one safe way to turn user text into an SQLite FTS5 `MATCH` expression.

  `BrowserHistory` and `Memory` each carried a private copy of this until
  10-16 (CODE_QUALITY_SWEEP Phase 4) — the kind of pair that drifts apart
  silently, because the next FTS5 operator someone's query trips over gets
  fixed in whichever file they happened to be reading.
  """

  @doc """
  Extract alphanumeric terms, quote each so punctuation and FTS5 operators in
  the input cannot break the syntax, and OR them for broad recall — bm25
  `rank` then orders by relevance. `:empty` when the query holds no term.
  """
  @spec match(term()) :: String.t() | :empty
  def match(query) do
    terms =
      query
      |> to_string()
      |> String.downcase()
      |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
      |> List.flatten()

    case terms do
      [] -> :empty
      ts -> Enum.map_join(ts, " OR ", &~s("#{&1}"))
    end
  end
end
