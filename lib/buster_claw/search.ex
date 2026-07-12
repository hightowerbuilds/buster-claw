defmodule BusterClaw.Search do
  @moduledoc "Bounded web search through DuckDuckGo HTML results."

  @endpoint "https://duckduckgo.com/html/"
  @user_agent "BusterClaw/2.0 ElixirRewrite"

  defmodule Result do
    @moduledoc "Normalized web search result."

    defstruct [:title, :url, :snippet]
  end

  def search(query, opts \\ []) do
    query = String.trim(to_string(query))

    if query == "" do
      {:error, :empty_query}
    else
      limit = Keyword.get(opts, :limit, 5)

      with {:ok, body} <- fetch(query, opts) do
        results =
          body
          |> parse_results()
          |> Enum.take(limit)

        {:ok, results}
      end
    end
  end

  def format_results([]), do: "No search results found."

  def format_results(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {%Result{} = result, index} ->
      snippet =
        result.snippet
        |> to_string()
        |> String.trim()

      [
        "#{index}. #{result.title}",
        result.url,
        snippet
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end)
  end

  def parse_results(body) do
    body
    |> String.split(~r/<div[^>]+class=["'][^"']*result[^"']*["'][^>]*>/i)
    |> Enum.drop(1)
    |> Enum.map(&parse_result_block/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.url)
  end

  defp fetch(query, opts) do
    req_options =
      Application.get_env(:buster_claw, :search_req_options, [])
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    request_options =
      [
        params: [q: query],
        headers: [{"user-agent", @user_agent}, {"accept", "text/html"}],
        receive_timeout: Keyword.get(opts, :timeout, 10_000),
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.get(@endpoint, request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, to_string(body)}

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_result_block(block) do
    case result_link(block) do
      {:ok, title, url} ->
        %Result{
          title: title,
          url: url,
          snippet: snippet(block)
        }

      {:error, _reason} ->
        nil
    end
  end

  defp result_link(block) do
    patterns = [
      ~r/<a[^>]+class=["'][^"']*result__a[^"']*["'][^>]+href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is,
      ~r/<a[^>]+href=["']([^"']+)["'][^>]+class=["'][^"']*result__a[^"']*["'][^>]*>(.*?)<\/a>/is
    ]

    Enum.find_value(patterns, {:error, :no_link}, fn pattern ->
      case Regex.run(pattern, block) do
        [_, href, title] ->
          {:ok, clean_text(title), normalize_url(href)}

        _ ->
          nil
      end
    end)
  end

  defp snippet(block) do
    case Regex.run(~r/<a[^>]+class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)<\/a>/is, block) ||
           Regex.run(
             ~r/<div[^>]+class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)<\/div>/is,
             block
           ) do
      [_, text] -> clean_text(text)
      _ -> ""
    end
  end

  defp normalize_url("//" <> rest), do: "https://" <> rest

  defp normalize_url(url) do
    url
    |> html_entities()
    |> URI.decode_www_form()
    |> unwrap_duckduckgo_url()
  end

  defp unwrap_duckduckgo_url(url) do
    uri = URI.parse(url)

    case URI.decode_query(uri.query || "") do
      %{"uddg" => target} -> target
      _ -> url
    end
  end

  defp clean_text(text) do
    text
    |> String.replace(~r/<[^>]+>/, " ")
    |> html_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end
end
