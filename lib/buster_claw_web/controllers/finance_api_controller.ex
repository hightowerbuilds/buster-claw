defmodule BusterClawWeb.FinanceApiController do
  @moduledoc """
  Loopback JSON surface for finance pages in `<workspace>/pages/` (served in
  the in-app browser's sandboxed content webview, which can't hold the API
  token). Originally built for the retired bundled financial-informant.html;
  kept for agent-built pages. Read-only, safe-tier finance data only (SEC EDGAR + Finnhub via
  `BusterClaw.Finance`); no auth, loopback-only — the same trust posture as the
  `/browser/*` and `/ws/*` raw scopes.

  - `GET /finance/api/search?q=` → `{ok, suggestions: [%{symbol, name}]}`
  - `GET /finance/api/lookup?q=` → resolve + quote/fundamentals/filings/news,
    each as `{ok, data}` or `{ok: false, error, not_configured}`.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Finance

  # Typeahead. Mirrors the LiveView: only search once the query is ≥ 2 chars
  # (keeps single keystrokes off the network).
  def search(conn, params) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()

    suggestions =
      if String.length(query) >= 2 do
        case Finance.search(query, limit: 8) do
          {:ok, list} -> list
          _ -> []
        end
      else
        []
      end

    json(conn, %{ok: true, suggestions: suggestions})
  end

  def lookup(conn, params) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()

    if query == "" do
      json(conn, %{ok: false, error: "Enter a ticker or company name."})
    else
      case Finance.resolve(query) do
        {:ok, symbol} ->
          json(conn, %{
            ok: true,
            symbol: symbol,
            name: company_name(symbol),
            quote: section(Finance.quote(symbol)),
            fundamentals: section(Finance.fundamentals(symbol)),
            filings: section(Finance.filings(symbol)),
            news: section(Finance.news(symbol))
          })

        {:error, _reason} ->
          json(conn, %{ok: false, error: "No company found for “#{query}”."})
      end
    end
  end

  # Company name from whichever source returned it; falls back to the symbol.
  defp company_name(symbol) do
    [Finance.filings(symbol), Finance.fundamentals(symbol)]
    |> Enum.find_value(fn
      {:ok, %{company: c}} when is_binary(c) and c != "" -> c
      _ -> nil
    end)
    |> Kernel.||(symbol)
  end

  defp section({:ok, data}), do: %{ok: true, data: data}
  defp section({:error, :not_configured}), do: %{ok: false, not_configured: true, error: nil}
  defp section({:error, reason}), do: %{ok: false, error: error_message(reason)}

  defp error_message({:unknown_symbol, sym}), do: "No match for #{sym} in the SEC ticker list."
  defp error_message(:missing_symbol), do: "Enter a ticker symbol."
  defp error_message({:http_error, status, _body}), do: "Source returned HTTP #{status}."
  defp error_message(reason), do: "Couldn't fetch: #{inspect(reason)}"
end
