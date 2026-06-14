defmodule BusterClaw.Finance.Edgar do
  @moduledoc """
  SEC EDGAR client — free, no API key. Resolves a ticker to its CIK, then reads
  recent filings (`submissions`) and XBRL fundamentals (`companyfacts`).

  EDGAR requires a descriptive `User-Agent` with a contact email and asks callers
  to stay under 10 requests/sec. The User-Agent is read from
  `:buster_claw, :finance_user_agent`; set it to a real contact before relying on
  this in production.

  Every result carries its `source`, `source_url`, and an `as_of` timestamp so no
  figure is ever presented without provenance.
  """

  @ticker_url "https://www.sec.gov/files/company_tickers.json"
  @data_host "https://data.sec.gov"
  @default_user_agent "BusterClaw/0.1 (financial research; set :buster_claw, :finance_user_agent)"
  @default_filings_limit 10

  # us-gaap concepts surfaced by `fundamentals/2`, in display order. Anything
  # missing from a company's facts is reported as unavailable, never guessed.
  @fundamental_concepts [
    {:revenue, ["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax"]},
    {:net_income, ["NetIncomeLoss"]},
    {:assets, ["Assets"]},
    {:liabilities, ["Liabilities"]},
    {:stockholders_equity, ["StockholdersEquity"]}
  ]

  @doc "Recent filings for `symbol` (10-K/10-Q/8-K …), newest first."
  def filings(symbol, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_filings_limit)

    with {:ok, %{cik: cik, title: title}} <- resolve_cik(symbol, opts),
         {:ok, body} <- get_json("#{@data_host}/submissions/CIK#{cik}.json", opts) do
      {:ok,
       %{
         symbol: String.upcase(symbol),
         cik: cik,
         company: title,
         source: "SEC EDGAR",
         source_url: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=#{cik}",
         as_of: now(),
         filings: parse_filings(body, cik, limit)
       }}
    end
  end

  @doc "Latest XBRL fundamentals for `symbol` (curated us-gaap concepts)."
  def fundamentals(symbol, opts \\ []) do
    with {:ok, %{cik: cik, title: title}} <- resolve_cik(symbol, opts),
         {:ok, body} <- get_json("#{@data_host}/api/xbrl/companyfacts/CIK#{cik}.json", opts) do
      {:ok,
       %{
         symbol: String.upcase(symbol),
         cik: cik,
         company: title,
         source: "SEC EDGAR (XBRL companyfacts)",
         source_url: "#{@data_host}/api/xbrl/companyfacts/CIK#{cik}.json",
         as_of: now(),
         facts: parse_facts(body)
       }}
    end
  end

  @doc "Resolve a ticker symbol to its zero-padded 10-digit CIK and company title."
  def resolve_cik(symbol, opts \\ []) do
    key = symbol |> to_string() |> String.trim() |> String.upcase()

    with {:ok, map} <- ticker_map(opts) do
      case Map.get(map, key) do
        nil -> {:error, {:unknown_symbol, key}}
        entry -> {:ok, entry}
      end
    end
  end

  @doc """
  Typeahead search over the SEC ticker list by **ticker or company name**.
  Returns `[%{symbol, name}]` ranked best-first (exact ticker → ticker prefix →
  name prefix → name/ticker substring), capped at `:limit` (default 8).
  """
  def search(query, opts \\ []) do
    q = query |> to_string() |> String.trim() |> String.downcase()
    limit = Keyword.get(opts, :limit, 8)

    if q == "" do
      {:ok, []}
    else
      with {:ok, map} <- ticker_map(opts) do
        results =
          map
          |> Enum.reduce([], fn {ticker, %{title: title}}, acc ->
            case match_score(String.downcase(ticker), String.downcase(to_string(title)), q) do
              nil -> acc
              score -> [{score, ticker, title} | acc]
            end
          end)
          |> Enum.sort_by(fn {score, ticker, title} ->
            {score, String.length(ticker), String.downcase(to_string(title))}
          end)
          |> Enum.take(limit)
          |> Enum.map(fn {_score, ticker, title} -> %{symbol: ticker, name: title} end)

        {:ok, results}
      end
    end
  end

  @doc "Resolve a free-text query (ticker or company name) to a ticker symbol."
  def resolve(query, opts \\ []) do
    key = query |> to_string() |> String.trim() |> String.upcase()

    with {:ok, map} <- ticker_map(opts) do
      if Map.has_key?(map, key) do
        {:ok, key}
      else
        case search(query, Keyword.put(opts, :limit, 1)) do
          {:ok, [%{symbol: sym} | _]} -> {:ok, sym}
          {:ok, []} -> {:error, :no_match}
          other -> other
        end
      end
    end
  end

  defp match_score(ticker, title, q) do
    cond do
      ticker == q -> 0
      String.starts_with?(ticker, q) -> 1
      String.starts_with?(title, q) -> 2
      String.contains?(title, q) -> 3
      String.contains?(ticker, q) -> 4
      true -> nil
    end
  end

  # --- ticker → CIK map (cached; the source file is large and rarely changes) ---

  defp ticker_map(opts) do
    case :persistent_term.get({__MODULE__, :ticker_map}, nil) do
      nil ->
        with {:ok, body} <- get_json(@ticker_url, opts) do
          map = build_ticker_map(body)
          :persistent_term.put({__MODULE__, :ticker_map}, map)
          {:ok, map}
        end

      map ->
        {:ok, map}
    end
  end

  defp build_ticker_map(body) when is_map(body) do
    body
    |> Map.values()
    |> Enum.reduce(%{}, fn row, acc ->
      ticker = row |> Map.get("ticker") |> to_string() |> String.upcase()

      if ticker == "" do
        acc
      else
        Map.put(acc, ticker, %{
          cik: pad_cik(Map.get(row, "cik_str")),
          title: Map.get(row, "title")
        })
      end
    end)
  end

  defp build_ticker_map(_body), do: %{}

  defp pad_cik(cik) when is_integer(cik),
    do: cik |> Integer.to_string() |> String.pad_leading(10, "0")

  defp pad_cik(cik) when is_binary(cik), do: cik |> String.trim() |> String.pad_leading(10, "0")

  # --- filings parsing (the recent block is column-oriented parallel arrays) ---

  defp parse_filings(%{"filings" => %{"recent" => recent}}, cik, limit) when is_map(recent) do
    forms = List.wrap(recent["form"])
    dates = List.wrap(recent["filingDate"])
    reports = List.wrap(recent["reportDate"])
    accessions = List.wrap(recent["accessionNumber"])
    docs = List.wrap(recent["primaryDocument"])

    [forms, dates, reports, accessions, docs]
    |> zip_columns()
    |> Enum.take(limit)
    |> Enum.map(fn [form, filing_date, report_date, accession, doc] ->
      %{
        form: form,
        filing_date: filing_date,
        report_date: blank_to_nil(report_date),
        accession: accession,
        url: filing_url(cik, accession, doc)
      }
    end)
  end

  defp parse_filings(_body, _cik, _limit), do: []

  defp zip_columns(columns) do
    rows = columns |> Enum.map(&length/1) |> Enum.min(fn -> 0 end)
    for i <- 0..(rows - 1)//1, rows > 0, do: Enum.map(columns, &Enum.at(&1, i))
  end

  defp filing_url(_cik, accession, doc) when accession in [nil, ""] or doc in [nil, ""], do: nil

  defp filing_url(cik, accession, doc) do
    plain = String.replace(accession, "-", "")
    "https://www.sec.gov/Archives/edgar/data/#{String.to_integer(cik)}/#{plain}/#{doc}"
  end

  # --- fundamentals parsing (pick the most recent value per concept) ---

  defp parse_facts(%{"facts" => %{"us-gaap" => gaap}}) when is_map(gaap) do
    Map.new(@fundamental_concepts, fn {key, concepts} ->
      {key, latest_fact(gaap, concepts)}
    end)
  end

  defp parse_facts(_body), do: Map.new(@fundamental_concepts, fn {key, _} -> {key, nil} end)

  defp latest_fact(gaap, concepts) do
    Enum.find_value(concepts, fn concept ->
      with %{"units" => units} <- Map.get(gaap, concept),
           {unit, entries} <-
             Enum.find(units, fn {_unit, list} -> is_list(list) and list != [] end) do
        entries
        |> Enum.filter(&is_map/1)
        |> Enum.max_by(&fact_sort_key/1, fn -> nil end)
        |> case do
          nil ->
            nil

          best ->
            %{
              value: best["val"],
              unit: unit,
              as_of: best["end"],
              form: best["form"],
              fiscal_year: best["fy"]
            }
        end
      else
        _ -> nil
      end
    end)
  end

  defp fact_sort_key(entry), do: to_string(entry["end"] || "")

  # --- HTTP ---

  defp get_json(url, opts) do
    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        url: url,
        headers: [{"user-agent", user_agent()}, {"accept", "application/json"}],
        receive_timeout: Keyword.get(opts, :timeout, 15_000),
        retry: false
      )

    case Req.get(req_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp user_agent, do: Application.get_env(:buster_claw, :finance_user_agent, @default_user_agent)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
