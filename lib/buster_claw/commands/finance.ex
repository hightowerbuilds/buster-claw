defmodule BusterClaw.Commands.Finance do
  @moduledoc "Read-only finance research commands (filings, fundamentals, quote, news). Delegated to from `BusterClaw.Commands`."

  alias BusterClaw.ChartBuilder.DataReq
  alias BusterClaw.Finance
  alias BusterClaw.Finance.Sources

  @doc """
  The source registry: what this app knows how to reach, and how far anyone has
  checked.

  `fetchable` is the part that matters operationally — a source is only
  fetchable if it is `:verified` AND has an adapter. Everything else is listed so
  the *decision* is discoverable: a `:blocked` source has a terms problem, an
  `:unsanctioned` one has no licence, and a `:dead` one used to work. Each is a
  record of an answer, not a to-do.
  """
  def finance_sources(args \\ %{}) do
    fetchable = DataReq.source_keys()
    sources = filter_status(Sources.all(), Map.get(args, "status"))

    {:ok,
     %{
       count: length(sources),
       fetchable: fetchable,
       # Named, and created, because a registry you cannot correct is a
       # reference book rather than a registry. This is the one moment an
       # operator is plainly asking about sources, so it is where the folder
       # they would add one to comes into existence.
       overrides_dir: Sources.ensure_dir(),
       sources: Enum.map(sources, &present(&1, fetchable))
     }}
  end

  defp filter_status(sources, status) when is_binary(status) and status != "" do
    wanted = status |> String.trim() |> String.downcase()
    Enum.filter(sources, &(to_string(&1.status) == wanted))
  end

  defp filter_status(sources, _status), do: sources

  defp present(source, fetchable) do
    source
    |> Map.take([
      :key,
      :name,
      :base_url,
      :auth,
      :cost,
      :answers,
      :series_hint,
      :rate_limit,
      :terms,
      :note
    ])
    |> Map.merge(%{
      status: to_string(source.status),
      # Stated rather than implied. `:verified` with no date would be a claim
      # nobody can check, and "verified a long time ago" is a thing the caller
      # should be able to see for themselves.
      verified_on: source.verified_on && Date.to_iso8601(source.verified_on),
      fetchable: source.key in fetchable
    })
  end

  def finance_filings(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.filings(symbol)

  def finance_filings(_args), do: {:error, :missing_symbol}

  def finance_fundamentals(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.fundamentals(symbol)

  def finance_fundamentals(_args), do: {:error, :missing_symbol}

  def finance_quote(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.quote(symbol)

  def finance_quote(_args), do: {:error, :missing_symbol}

  def finance_news(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.news(symbol)

  def finance_news(_args), do: {:error, :missing_symbol}
end
