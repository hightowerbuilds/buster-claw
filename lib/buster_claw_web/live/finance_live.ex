defmodule BusterClawWeb.FinanceLive do
  @moduledoc """
  Financial Informant dashboard — look up a ticker or company and see its quote, fundamentals,
  recent SEC filings, and news. Read-only research: every figure is shown with its
  source and as-of timestamp, and the page is explicitly labeled "not financial
  advice." Backed by `BusterClaw.Finance` (EDGAR + Finnhub).
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Finance

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Financial Informant")
     |> assign(:query, "")
     |> assign(:symbol, nil)
     |> assign(:suggestions, [])
     |> assign(:results, nil)}
  end

  @impl true
  def handle_event("suggest", %{"symbol" => raw}, socket) do
    query = to_string(raw)

    suggestions =
      if String.length(String.trim(query)) >= 2 do
        case Finance.search(query, limit: 8) do
          {:ok, list} -> list
          _ -> []
        end
      else
        []
      end

    {:noreply, assign(socket, query: query, suggestions: suggestions)}
  end

  def handle_event("lookup", %{"symbol" => raw}, socket) do
    query = String.trim(to_string(raw))

    cond do
      query == "" ->
        {:noreply, assign(socket, query: "", symbol: nil, results: nil, suggestions: [])}

      true ->
        case Finance.resolve(query) do
          {:ok, symbol} ->
            results = %{
              quote: Finance.quote(symbol),
              fundamentals: Finance.fundamentals(symbol),
              filings: Finance.filings(symbol),
              news: Finance.news(symbol)
            }

            {:noreply,
             assign(socket, query: symbol, symbol: symbol, results: results, suggestions: [])}

          {:error, _reason} ->
            {:noreply,
             assign(socket, query: query, symbol: query, results: :no_match, suggestions: [])}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="finance" class="flex flex-1 flex-col space-y-6">
        <div class="border-b-2 border-base-content/20 pb-5">
          <p class="ic-eyebrow">Markets</p>
          <h1 class="font-display text-3xl font-black uppercase tracking-tight">
            Financial Informant
          </h1>
          <p class="mt-1 text-sm text-base-content/65">
            Search by ticker or company name — every figure carries its source and as-of date.
            <span class="font-semibold">Not financial advice.</span>
          </p>

          <form phx-change="suggest" phx-submit="lookup" class="mt-4 flex flex-wrap items-start gap-2">
            <div class="relative w-80 max-w-full">
              <input
                type="text"
                name="symbol"
                value={@query}
                autocomplete="off"
                spellcheck="false"
                phx-debounce="200"
                placeholder="Ticker or company — e.g. AAPL or Apple"
                class="input w-full font-mono"
              />
              <ul
                :if={@suggestions != []}
                class="absolute z-20 mt-1 max-h-72 w-full overflow-auto rounded-sm border-2 border-base-content/25 bg-base-100 shadow-lg"
              >
                <li :for={s <- @suggestions}>
                  <button
                    type="button"
                    phx-click="lookup"
                    phx-value-symbol={s.symbol}
                    class="flex w-full items-baseline gap-2 px-3 py-2 text-left text-sm hover:bg-base-200"
                  >
                    <span class="shrink-0 font-mono font-bold">{s.symbol}</span>
                    <span class="truncate text-base-content/65">{s.name}</span>
                  </button>
                </li>
              </ul>
            </div>
            <button
              type="submit"
              phx-disable-with="Looking up…"
              class="rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
            >
              Look up
            </button>
          </form>
        </div>

        <div
          :if={is_nil(@results)}
          class="rounded border border-dashed border-base-300 px-4 py-16 text-center text-sm text-base-content/60"
        >
          Search by ticker or company name to see its quote, fundamentals, recent filings, and news.
        </div>

        <div
          :if={@results == :no_match}
          class="rounded border border-dashed border-base-300 px-4 py-16 text-center text-sm text-base-content/60"
        >
          No company found for <span class="font-mono">{@symbol}</span>. Try a ticker (AAPL) or a
          company name (Apple).
        </div>

        <div :if={is_map(@results)} class="grid gap-6 lg:grid-cols-2">
          <.quote_card result={@results.quote} symbol={@symbol} />
          <.fundamentals_card result={@results.fundamentals} />
          <.filings_card result={@results.filings} />
          <.news_card result={@results.news} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  # --- cards --------------------------------------------------------------

  attr :result, :any, required: true
  attr :symbol, :string, required: true

  defp quote_card(assigns) do
    ~H"""
    <.card title="Quote">
      <%= case @result do %>
        <% {:ok, q} -> %>
          <div class="flex items-baseline gap-3">
            <span class="font-display text-3xl font-black">{fmt_price(q.price)}</span>
            <span class={["font-mono text-sm font-semibold", change_class(q.change)]}>
              {fmt_signed(q.change)} ({fmt_signed(q.percent_change)}%)
            </span>
          </div>
          <dl class="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 font-mono text-xs text-base-content/70">
            <div class="flex justify-between">
              <dt>Open</dt>
              <dd>{fmt_price(q.open)}</dd>
            </div>
            <div class="flex justify-between">
              <dt>Prev close</dt>
              <dd>{fmt_price(q.previous_close)}</dd>
            </div>
            <div class="flex justify-between">
              <dt>High</dt>
              <dd>{fmt_price(q.high)}</dd>
            </div>
            <div class="flex justify-between">
              <dt>Low</dt>
              <dd>{fmt_price(q.low)}</dd>
            </div>
          </dl>
          <p class="mt-2 text-xs italic text-base-content/50">{q.note}</p>
          <.provenance source={q.source} as_of={q.as_of} />
        <% {:error, :not_configured} -> %>
          <.not_configured />
        <% {:error, reason} -> %>
          <.error reason={reason} />
      <% end %>
    </.card>
    """
  end

  attr :result, :any, required: true

  defp fundamentals_card(assigns) do
    ~H"""
    <.card title="Fundamentals">
      <%= case @result do %>
        <% {:ok, f} -> %>
          <p class="text-sm font-semibold">{f.company}</p>
          <dl class="mt-2 divide-y divide-base-300 text-sm">
            <.fact label="Revenue" fact={f.facts.revenue} />
            <.fact label="Net income" fact={f.facts.net_income} />
            <.fact label="Assets" fact={f.facts.assets} />
            <.fact label="Liabilities" fact={f.facts.liabilities} />
            <.fact label="Shareholders' equity" fact={f.facts.stockholders_equity} />
          </dl>
          <.provenance source={f.source} as_of={f.as_of} />
        <% {:error, reason} -> %>
          <.error reason={reason} />
      <% end %>
    </.card>
    """
  end

  attr :result, :any, required: true

  defp filings_card(assigns) do
    ~H"""
    <.card title="Recent Filings">
      <%= case @result do %>
        <% {:ok, %{filings: []}} -> %>
          <p class="text-sm text-base-content/60">No recent filings.</p>
        <% {:ok, f} -> %>
          <ul class="divide-y divide-base-300 text-sm">
            <li :for={filing <- f.filings} class="flex items-center justify-between gap-3 py-2">
              <span class="flex min-w-0 items-center gap-2">
                <span class="rounded bg-base-200 px-2 py-0.5 font-mono text-xs font-bold">
                  {filing.form}
                </span>
                <span class="font-mono text-xs text-base-content/70">{filing.filing_date}</span>
              </span>
              <a
                :if={filing.url}
                href={filing.url}
                target="_blank"
                rel="noopener"
                class="shrink-0 font-mono text-xs text-primary hover:underline"
              >
                view ↗
              </a>
            </li>
          </ul>
          <.provenance source={f.source} as_of={f.as_of} />
        <% {:error, reason} -> %>
          <.error reason={reason} />
      <% end %>
    </.card>
    """
  end

  attr :result, :any, required: true

  defp news_card(assigns) do
    ~H"""
    <.card title="News">
      <%= case @result do %>
        <% {:ok, %{articles: []}} -> %>
          <p class="text-sm text-base-content/60">No recent news.</p>
        <% {:ok, n} -> %>
          <ul class="divide-y divide-base-300 text-sm">
            <li :for={article <- n.articles} class="py-2">
              <a
                href={article.url}
                target="_blank"
                rel="noopener"
                class="font-semibold text-primary hover:underline"
              >
                {article.headline}
              </a>
              <p class="mt-0.5 font-mono text-[0.68rem] uppercase tracking-wide text-base-content/55">
                {article.source} · {fmt_date(article.as_of)}
              </p>
            </li>
          </ul>
          <.provenance source={n.source} as_of={n.as_of} />
        <% {:error, :not_configured} -> %>
          <.not_configured />
        <% {:error, reason} -> %>
          <.error reason={reason} />
      <% end %>
    </.card>
    """
  end

  # --- shared bits --------------------------------------------------------

  slot :inner_block, required: true
  attr :title, :string, required: true

  defp card(assigns) do
    ~H"""
    <section class="ic-panel flex flex-col p-5">
      <h2 class="font-display text-xl font-black uppercase tracking-tight">{@title}</h2>
      <div class="mt-3 flex-1">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :fact, :any, required: true

  defp fact(%{fact: nil} = assigns) do
    ~H"""
    <div class="flex items-center justify-between py-1.5">
      <dt class="text-base-content/70">{@label}</dt>
      <dd class="font-mono text-xs text-base-content/40">unavailable</dd>
    </div>
    """
  end

  defp fact(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-1.5">
      <dt class="text-base-content/70">{@label}</dt>
      <dd class="text-right">
        <span class="font-mono font-semibold">{fmt_number(@fact.value)} {@fact.unit}</span>
        <span class="block font-mono text-[0.62rem] uppercase tracking-wide text-base-content/45">
          {@fact.form} · as of {@fact.as_of}
        </span>
      </dd>
    </div>
    """
  end

  attr :source, :string, required: true
  attr :as_of, :string, required: true

  defp provenance(assigns) do
    ~H"""
    <p class="mt-4 border-t border-base-300 pt-2 font-mono text-[0.62rem] uppercase tracking-wide text-base-content/45">
      Source: {@source} · as of {fmt_date(@as_of)}
    </p>
    """
  end

  defp not_configured(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">
      Not configured. Set <code class="font-mono">FINNHUB_API_KEY</code>
      and restart to enable live quotes and news.
    </p>
    """
  end

  attr :reason, :any, required: true

  defp error(assigns) do
    ~H"""
    <p class="font-mono text-xs text-warning">{error_message(@reason)}</p>
    """
  end

  defp error_message({:unknown_symbol, sym}), do: "No match for #{sym} in the SEC ticker list."
  defp error_message(:missing_symbol), do: "Enter a ticker symbol."
  defp error_message({:http_error, status, _body}), do: "Source returned HTTP #{status}."
  defp error_message(reason), do: "Couldn't fetch: #{inspect(reason)}"

  # --- formatting ---------------------------------------------------------

  defp change_class(change) when is_number(change) and change < 0, do: "text-error"
  defp change_class(change) when is_number(change) and change > 0, do: "text-success"
  defp change_class(_change), do: "text-base-content/60"

  defp fmt_price(value) when is_number(value),
    do: "$#{:erlang.float_to_binary(value / 1.0, decimals: 2)}"

  defp fmt_price(_value), do: "—"

  defp fmt_signed(value) when is_number(value) and value > 0,
    do: "+#{:erlang.float_to_binary(value / 1.0, decimals: 2)}"

  defp fmt_signed(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1.0, decimals: 2)

  defp fmt_signed(_value), do: "—"

  defp fmt_number(value) when is_integer(value), do: delimit(value)
  defp fmt_number(value) when is_float(value), do: delimit(round(value))
  defp fmt_number(value), do: to_string(value)

  defp delimit(int) do
    sign = if int < 0, do: "-", else: ""

    digits =
      int
      |> abs()
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.join/1)
      |> Enum.join(",")
      |> String.reverse()

    sign <> digits
  end

  defp fmt_date(nil), do: "—"

  defp fmt_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso
    end
  end

  defp fmt_date(value), do: to_string(value)
end
