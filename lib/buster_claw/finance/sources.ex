defmodule BusterClaw.Finance.Sources do
  @moduledoc """
  The source registry — where financial data legitimately comes from
  (`CHART_BUILD_WEB_DATA_ROADMAP` Phase 3).

  Pure data. It knows what exists, what it answers, what it costs, and how far
  anyone has actually checked; it does no fetching. `ChartBuilder.DataReq` binds
  the fetchable ones to adapters.

  ## Why the catalogue is in CODE and the overrides are in the workspace

  The shipped list lives in `@builtins`, and operator additions merge over it
  from `<workspace>/sources/*.md` at read time — the `TerminalCommands` pattern.
  Not a seeded workspace file, deliberately: `maybe_write` skips anything that
  already exists (`LAUNCH_ROADMAP` V.8), so a seeded catalogue could never be
  corrected on a machine that had already run once. A registry of third-party
  APIs is the most update-prone thing in this application — free tiers close,
  endpoints move, terms change. It has to be patchable by shipping code.

  ## `status` is the load-bearing field

    * `:verified` — someone called it from this application and read the answer.
    * `:candidate` — documented, endpoint plausible, **never actually called**.
    * `:blocked` — reachable and working, but its terms forbid our use. Not a
      to-do. Someone decided.
    * `:unsanctioned` — works, but there is no licence permitting it.
    * `:dead` — was usable, is not now.

  Only `:verified` sources are ever fetchable, and only then if an adapter
  exists. Everything else is here so that the *decision* is discoverable rather
  than the endpoint being rediscovered — which is the entire point of recording
  `:unsanctioned` and `:dead` at all.

  `verified_on` is the date of the last real call. It is allowed to go stale;
  what is not allowed is for it to be absent while `status` claims `:verified`.
  """

  require Logger

  alias BusterClaw.Library.{Artifact, Frontmatter}

  @subdir "sources"

  # Probed 2026-08-03 from a real machine. Anything marked :verified below was
  # called and its body read; anything :candidate was not, and says so.
  @builtins [
    %{
      key: "bls",
      name: "U.S. Bureau of Labor Statistics",
      base_url: "https://api.bls.gov/publicAPI",
      auth: :none,
      cost: "free; a free key (email, no card) raises 25 → 500 queries/day",
      answers: "CPI, unemployment, PPI, employment, earnings — monthly",
      series_hint: "a BLS series id, e.g. CUUR0000SA0 (CPI-U) or LNS14000000 (unemployment)",
      rate_limit: "25 queries/day keyless, 500 registered",
      terms: "US federal government work; public domain",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "The primary publisher for CPI — FRED's CPIAUCSL republishes this exact series. " <>
          "Period M13 is the annual average, not a thirteenth month; failures arrive as HTTP 200."
    },
    %{
      key: "market",
      name: "Buster Claw market cache",
      base_url: nil,
      auth: :none,
      cost: "free — already fetched; reading it costs nothing",
      answers:
        "daily closing prices for held symbols and the tracked benchmarks " <>
          "(SPY, QQQ, DIA, IWM), about a year deep",
      series_hint: "a ticker already in the cache, e.g. SPY for the S&P 500",
      rate_limit: "none — it is a local table",
      terms: "the operator's own data, fetched through their own broker session",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "READ-ONLY from Chart Build's side: an uncached symbol returns 'not cached', never a " <>
          "broker fetch, so this tab still has no code path to a live broker read. The daily " <>
          "Recorder fills it out of band. Closes, not official index levels, and not " <>
          "dividend-adjusted — SPY is the S&P 500 as an ETF tracks it."
    },
    %{
      key: "edgar",
      name: "SEC EDGAR",
      base_url: "https://data.sec.gov",
      auth: :none,
      cost: "free",
      answers: "company filings (10-K/10-Q/8-K) and XBRL fundamentals",
      series_hint: "a ticker symbol",
      rate_limit: "stay under 10 requests/sec; requires a descriptive User-Agent",
      terms: "US federal government work; public domain",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note: "Wired as `BusterClaw.Finance.Edgar`, and behind the Chart Build lookup panel."
    },
    %{
      key: "finnhub",
      name: "Finnhub",
      base_url: "https://finnhub.io/api/v1",
      auth: :key,
      cost: "free tier; key required (FINNHUB_API_KEY)",
      answers: "US equity quotes and company news",
      series_hint: "a ticker symbol",
      rate_limit: "free-tier limits apply; quotes ~15 minutes delayed",
      terms: "vendor terms; free tier for non-commercial use — review before charging",
      status: :verified,
      verified_on: ~D[2026-08-04],
      note:
        "Wired as `BusterClaw.Finance.Finnhub`. Never describe a free-tier quote as live. " <>
          "NO OHLC HISTORY on the free tier: `/stock/candle` answers HTTP 403 " <>
          "\"You don't have access to this resource\" with a key whose `/quote` returns 200 " <>
          "in the same minute (measured 08-04). So this cannot back the market cache, and " <>
          "the deep backfill stays on the ~$0.57 broker+model path. Recorded so the DECISION " <>
          "is findable rather than the endpoint being retried."
    },
    %{
      key: "treasury_fiscal",
      name: "U.S. Treasury Fiscal Data",
      base_url: "https://api.fiscaldata.treasury.gov/services/api/fiscal_service",
      auth: :none,
      cost: "free",
      answers: "public debt, average interest rates, auction results, exchange rates",
      series_hint: "an endpoint path, e.g. /v2/accounting/od/debt_to_penny",
      rate_limit: "none documented",
      terms:
        "explicitly free to copy, adapt, redistribute for non-commercial OR COMMERCIAL use — " <>
          "the cleanest licence in this registry",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "All values are STRINGS, including numerics. Rates of exchange is /v1, not /v2. " <>
          "The yield curve is NOT here — see treasury_yield_curve."
    },
    %{
      key: "treasury_yield_curve",
      name: "Daily Treasury Par Yield Curve Rates",
      base_url: "https://home.treasury.gov/resource-center/data-chart-center/interest-rates",
      auth: :none,
      cost: "free",
      answers: "the par yield curve, 1Mo through 30Yr, daily, in percent",
      series_hint: "a calendar year",
      rate_limit: "none documented",
      terms: "US federal government work; public domain",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "CSV, one year per request; dates are MM/DD/YYYY, not ISO. Needs a browser-ish " <>
          "User-Agent and HTTP/1.1. Probably the most chart-worthy free series there is."
    },
    %{
      key: "worldbank",
      name: "World Bank Indicators",
      base_url: "https://api.worldbank.org/v2",
      auth: :none,
      cost: "free",
      answers: "~1,500 global indicators × ~200 countries — GDP, inflation, population, trade",
      series_hint: "an indicator code, e.g. NY.GDP.MKTP.CD",
      rate_limit: "none documented",
      terms: "CC-BY 4.0 — commercial use permitted with attribution",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "The response is a TWO-ELEMENT array: [0] is pagination, [1] is the observations. " <>
          "Mostly annual. Missing values arrive as null — do not coerce to 0."
    },
    %{
      key: "ecb",
      name: "European Central Bank Data Portal",
      base_url: "https://data-api.ecb.europa.eu/service/data",
      auth: :none,
      cost: "free",
      answers: "euro reference FX, policy rates, euro-area HICP, yield curves",
      series_hint: "an SDMX key, e.g. EXR/D.USD.EUR.SP00.A",
      rate_limit: "none documented",
      terms: "reuse permitted with attribution; statistics must not be modified",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "Use format=csvdata. The jsondata form keys observations by POSITIONAL INDEX into a " <>
          "separate structure block, so reading it means joining two documents."
    },
    %{
      key: "frankfurter",
      name: "Frankfurter",
      base_url: "https://api.frankfurter.dev",
      auth: :none,
      cost: "free, open source, self-hostable",
      answers: "FX time series — 201 currencies from 84 central banks, back to 1948",
      series_hint: "a currency pair, e.g. base=EUR&symbols=USD",
      rate_limit: "none documented",
      terms: "open; the underlying rates carry their originating banks' terms",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "Prefer v1 for time series — v2's historical path returned Cloudflare 522s " <>
          "intermittently while probing on 08-03."
    },
    %{
      key: "fed_ddp",
      name: "Federal Reserve Board Data Download Program",
      base_url: "https://www.federalreserve.gov/datadownload/Output.aspx",
      auth: :none,
      cost: "free",
      answers: "H.15 interest rates, H.10 FX, G.17 industrial production, H.6 money stock",
      series_hint: "an opaque package hash from the DDP web UI",
      rate_limit: "none documented",
      terms: "US federal government work; public domain",
      status: :verified,
      verified_on: ~D[2026-08-03],
      note:
        "The primary for DGS10 and friends. The `series=` value is a hash you can only get " <>
          "from their web UI's package builder — real integration friction."
    },
    %{
      key: "bea",
      name: "U.S. Bureau of Economic Analysis",
      base_url: "https://apps.bea.gov/api/data/",
      auth: :key,
      cost: "free key (email, no card)",
      answers: "GDP, personal income, PCE, regional income, industry accounts",
      series_hint: "a dataset + table, e.g. NIPA/T10101",
      rate_limit: "100 requests/min, 100 MB/min, 30 errors/min",
      terms: "US federal government work; public domain",
      status: :candidate,
      verified_on: nil,
      note:
        "The primary for GDP. RETURNS HTTP 200 ON FAILURE — the error is in " <>
          "BEAAPI.Results.Error. Any adapter needs a body-level success check, not a status one."
    },
    %{
      key: "eia",
      name: "U.S. Energy Information Administration",
      base_url: "https://api.eia.gov/v2",
      auth: :key,
      cost: "free key (email, no card)",
      answers: "crude, gasoline, natural gas, electricity, coal, renewables",
      series_hint: "a route + facets, e.g. /petroleum/pri/spt/data/",
      rate_limit: "5,000 rows per response; throttling documented but unnumbered",
      terms: "US federal government work; public domain",
      status: :candidate,
      verified_on: nil,
      note: nil
    },
    %{
      key: "coingecko",
      name: "CoinGecko",
      base_url: "https://api.coingecko.com/api/v3",
      auth: :none,
      cost: "free Demo tier; paid from $35/mo",
      answers: "crypto spot prices, market caps, volumes",
      series_hint: "a coin id, e.g. bitcoin",
      rate_limit: "Demo plan 10k credits/month at 100 req/min",
      terms:
        "ATTRIBUTION REQUIRED on the free tier, and the commercial licence is reserved for " <>
          "paid plans — a live question for this app, which has a paid tier planned",
      status: :candidate,
      verified_on: nil,
      note:
        "Keyless calls succeeded on 08-03 even though the terms describe the Demo tier as " <>
          "key-required. Register a key and render the attribution before relying on it."
    },
    %{
      key: "fred",
      name: "Federal Reserve Economic Data (St. Louis Fed)",
      base_url: "https://api.stlouisfed.org/fred",
      auth: :key,
      cost: "free key",
      answers: "800k+ macro series — the largest catalogue anywhere",
      series_hint: "a FRED series id, e.g. CPIAUCSL",
      rate_limit: "~120 req/min (documented secondhand; unconfirmed)",
      terms:
        "PROHIBITS use in connection with machine learning or large language models, AND " <>
          "prohibits storing, caching or archiving its content",
      status: :blocked,
      verified_on: nil,
      note:
        "DROPPED BY OPERATOR DECISION, 08-03. Not a to-do and not a question — do not " <>
          "re-open it by writing an adapter. Both clauses land squarely on what this " <>
          "application does, and FRED is a REDISTRIBUTOR: CPIAUCSL is BLS, GDP is BEA, DGS10 " <>
          "is the Fed Board's H.15 — all three primaries are in this registry, verified, with " <>
          "no such restriction. What FRED offered was convenience (one API, one auth, one " <>
          "response shape) and catalogue breadth, not numbers we cannot otherwise get. The " <>
          "live terms page could not be read (the host bot-blocks curl and WebFetch alike); " <>
          "the wording above is from the Fed's own June 2024 change announcement. Reopening " <>
          "this needs a fresh operator decision, not just someone reading " <>
          "https://fred.stlouisfed.org/docs/api/terms_of_use.html — though anyone doing that " <>
          "should record what they found here. The decision predates that read and does not " <>
          "depend on it."
    },
    %{
      key: "alphavantage",
      name: "Alpha Vantage",
      base_url: "https://www.alphavantage.co/query",
      auth: :key,
      cost: "free tier; paid from $49.99/mo",
      answers: "equity quotes, time series, fundamentals",
      series_hint: "a function + symbol",
      rate_limit: "25 requests/DAY on the free tier",
      terms: "vendor terms",
      status: :candidate,
      verified_on: nil,
      note:
        "25 calls/day is a demo, not a data source for an interactive surface. Also returns " <>
          "HTTP 200 on failure. Low priority on purpose."
    },
    %{
      key: "nasdaq_datalink",
      name: "Nasdaq Data Link (formerly Quandl)",
      base_url: "https://data.nasdaq.com/api/v3",
      auth: :key,
      cost: "mostly premium now",
      answers: "mixed datasets; the free ones are Quandl-era residue",
      series_hint: nil,
      rate_limit: nil,
      terms: "vendor terms",
      status: :dead,
      verified_on: nil,
      note:
        "Server-side bot protection returned an Incapsula challenge to 4/4 unauthenticated " <>
          "API calls on 08-03. Free coverage largely superseded."
    },
    %{
      key: "yahoo_unofficial",
      name: "Yahoo Finance (unofficial endpoints)",
      base_url: "https://query1.finance.yahoo.com",
      auth: :none,
      cost: "free, in the sense that nobody said you could",
      answers: "equity quotes and OHLC history",
      series_hint: nil,
      rate_limit: "aggressive; HTTP 429 on the first unauthenticated request on 08-03",
      terms: "NONE — Yahoo publishes no free API and no terms permitting programmatic use",
      status: :unsanctioned,
      verified_on: nil,
      note:
        "Recorded so the DECISION is findable rather than the endpoint being rediscovered. " <>
          "Undocumented internals, crumb-gated and changed without notice: an unlicensed " <>
          "dependency that would break silently on a financial surface."
    }
  ]

  @doc "The shipped catalogue, before operator overrides."
  def builtins, do: @builtins

  @doc """
  Every source, operator overrides merged over the shipped list, sorted by key.

  An override with an existing `key` replaces that entry's named fields; a new
  key is added. Reading is best-effort — a malformed override is logged and
  skipped rather than taking the registry down with it.
  """
  def all do
    overrides = load_overrides()

    @builtins
    |> Enum.map(fn source -> Map.merge(source, Map.get(overrides, source.key, %{})) end)
    |> Kernel.++(new_overrides(overrides))
    |> Enum.sort_by(& &1.key)
  end

  @doc "One source by key, or `nil`."
  def get(key), do: Enum.find(all(), &(&1.key == key))

  @doc """
  Sources whose data we would actually put on a chart: `:verified` only.

  `:candidate` is excluded on purpose — it means nobody has called it, so its
  response shape is a guess, and a guess is not something to plot.
  """
  def verified, do: Enum.filter(all(), &(&1.status == :verified))

  @doc "Group by status, for the `finance_sources` listing."
  def by_status, do: Enum.group_by(all(), & &1.status)

  @doc "The directory operator overrides are read from."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc """
  Create the overrides directory, and return its path.

  `sources/` is an `:on_demand` workspace entry with no seeder, so nothing
  creates it at install — which is right, since an empty labelled drawer teaches
  nothing. But this registry is only ever *read*, so without this the folder
  would never exist at all and the override feature would be reachable only by an
  operator who guessed the directory name. Asking what sources exist is exactly
  the moment you would want somewhere to add one, so `finance_sources` calls
  this; nothing on a render path does.
  """
  def ensure_dir do
    path = dir()
    File.mkdir_p!(path)
    path
  end

  # --- overrides ---

  defp load_overrides do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&load_override/1)
        |> Enum.reject(&is_nil/1)
        |> Map.new(&{&1.key, &1})

      {:error, _reason} ->
        %{}
    end
  end

  defp load_override(filename) do
    path = Path.join(dir(), filename)
    key = filename |> Path.rootname() |> String.trim() |> String.downcase()

    case File.read(path) do
      {:ok, raw} ->
        %{fields: fields, body: body} = Frontmatter.split(raw)

        fields
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> to_override(key, body)

      {:error, _reason} ->
        Logger.warning("Sources: could not read override #{filename}")
        nil
    end
  rescue
    error ->
      Logger.warning("Sources: bad override #{filename}: #{Exception.message(error)}")
      nil
  end

  # Only fields an operator can sensibly correct are honoured. `status` is one of
  # them — a source going dead is exactly the kind of thing an operator learns
  # before we ship a new build — but it is parsed strictly, so a typo cannot
  # quietly promote something to :verified.
  defp to_override(meta, key, body) do
    base = %{key: key}

    base
    |> put_string(meta, "name", :name)
    |> put_string(meta, "base_url", :base_url)
    |> put_string(meta, "cost", :cost)
    |> put_string(meta, "answers", :answers)
    |> put_string(meta, "series_hint", :series_hint)
    |> put_string(meta, "rate_limit", :rate_limit)
    |> put_string(meta, "terms", :terms)
    |> put_status(meta)
    |> put_verified_on(meta)
    |> Map.put(:note, note_from(meta, body))
  end

  defp put_string(acc, meta, field, key) do
    case Map.get(meta, field) do
      value when is_binary(value) and value != "" -> Map.put(acc, key, value)
      _other -> acc
    end
  end

  @statuses ~w(verified candidate blocked unsanctioned dead)

  defp put_status(acc, meta) do
    case Map.get(meta, "status") do
      value when is_binary(value) ->
        if String.trim(value) in @statuses do
          Map.put(acc, :status, String.to_existing_atom(String.trim(value)))
        else
          acc
        end

      _other ->
        acc
    end
  end

  defp put_verified_on(acc, meta) do
    with value when is_binary(value) <- Map.get(meta, "verified_on"),
         {:ok, date} <- Date.from_iso8601(String.trim(value)) do
      Map.put(acc, :verified_on, date)
    else
      _other -> acc
    end
  end

  defp note_from(meta, body) do
    trimmed = body |> to_string() |> String.trim()

    cond do
      trimmed != "" -> trimmed
      is_binary(Map.get(meta, "note")) -> Map.get(meta, "note")
      true -> nil
    end
  end

  # An override for a key the shipped list does not have is a NEW source. It gets
  # conservative defaults: unknown auth, and `:candidate` unless it said
  # otherwise, so an operator adding a file cannot accidentally mint something
  # the fetch path treats as trustworthy.
  defp new_overrides(overrides) do
    known = MapSet.new(@builtins, & &1.key)

    overrides
    |> Enum.reject(fn {key, _value} -> MapSet.member?(known, key) end)
    |> Enum.map(fn {_key, value} ->
      %{
        key: nil,
        name: nil,
        base_url: nil,
        auth: :unknown,
        cost: nil,
        answers: nil,
        series_hint: nil,
        rate_limit: nil,
        terms: nil,
        status: :candidate,
        verified_on: nil,
        note: nil
      }
      |> Map.merge(value)
    end)
  end
end
