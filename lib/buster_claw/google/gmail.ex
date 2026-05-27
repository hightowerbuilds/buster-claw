defmodule BusterClaw.Google.Gmail do
  @moduledoc "Gmail read/search helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @default_limit 10
  @max_limit 50

  def labels(%Account{} = account, opts \\ []) do
    with {:ok, body} <- Client.get_json(account, "users/me/labels", opts) do
      labels =
        body
        |> Map.get("labels", [])
        |> Enum.map(&label_summary/1)

      {:ok, labels}
    end
  end

  def search(%Account{} = account, query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    params =
      [
        {"maxResults", Integer.to_string(limit)}
      ]
      |> maybe_put_query(query)

    with {:ok, body} <-
           Client.get_json(account, "users/me/messages", Keyword.put(opts, :params, params)) do
      messages =
        body
        |> Map.get("messages", [])
        |> Enum.take(limit)
        |> Enum.map(&fetch_summary(account, &1, opts))
        |> collect_ok()

      case messages do
        {:ok, items} ->
          {:ok,
           %{
             messages: items,
             result_size_estimate: Map.get(body, "resultSizeEstimate", length(items)),
             next_page_token: Map.get(body, "nextPageToken")
           }}

        error ->
          error
      end
    end
  end

  def read(%Account{} = account, message_id, opts \\ []) do
    path = "users/me/messages/#{URI.encode_www_form(to_string(message_id))}"
    opts = Keyword.put(opts, :params, [{"format", "full"}])

    with {:ok, body} <- Client.get_json(account, path, opts) do
      {:ok, parse_message(body)}
    end
  end

  defp fetch_summary(account, %{"id" => id}, opts) do
    path = "users/me/messages/#{URI.encode_www_form(id)}"

    params = [
      {"format", "metadata"},
      {"metadataHeaders", "Subject"},
      {"metadataHeaders", "From"},
      {"metadataHeaders", "Date"}
    ]

    with {:ok, body} <- Client.get_json(account, path, Keyword.put(opts, :params, params)) do
      {:ok, message_summary(body)}
    end
  end

  defp fetch_summary(_account, other, _opts), do: {:error, {:bad_message_ref, other}}

  defp collect_ok(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp parse_message(body) do
    payload = Map.get(body, "payload", %{})
    headers = headers_map(payload)
    {text, html} = message_bodies(payload)

    %{
      id: Map.get(body, "id"),
      thread_id: Map.get(body, "threadId"),
      history_id: Map.get(body, "historyId"),
      internal_date: parse_internal_date(Map.get(body, "internalDate")),
      snippet: Map.get(body, "snippet"),
      label_ids: Map.get(body, "labelIds", []),
      subject: Map.get(headers, "subject"),
      from: Map.get(headers, "from"),
      to: Map.get(headers, "to"),
      date: Map.get(headers, "date"),
      body_text: text || html_to_text(html),
      body_html: html,
      raw: body
    }
  end

  defp message_summary(body) do
    payload = Map.get(body, "payload", %{})
    headers = headers_map(payload)

    %{
      id: Map.get(body, "id"),
      thread_id: Map.get(body, "threadId"),
      history_id: Map.get(body, "historyId"),
      internal_date: parse_internal_date(Map.get(body, "internalDate")),
      snippet: Map.get(body, "snippet"),
      label_ids: Map.get(body, "labelIds", []),
      subject: Map.get(headers, "subject"),
      from: Map.get(headers, "from"),
      date: Map.get(headers, "date")
    }
  end

  defp label_summary(label) do
    %{
      id: Map.get(label, "id"),
      name: Map.get(label, "name"),
      type: Map.get(label, "type"),
      message_list_visibility: Map.get(label, "messageListVisibility"),
      label_list_visibility: Map.get(label, "labelListVisibility")
    }
  end

  defp headers_map(payload) do
    payload
    |> Map.get("headers", [])
    |> Map.new(fn header ->
      {header |> Map.get("name", "") |> String.downcase(), Map.get(header, "value")}
    end)
  end

  defp message_bodies(payload) do
    payload
    |> flatten_parts()
    |> Enum.reduce({nil, nil}, fn part, {text, html} ->
      decoded = part |> Map.get("body", %{}) |> Map.get("data") |> decode_base64url()

      case {Map.get(part, "mimeType"), decoded} do
        {"text/plain", value} when is_binary(value) -> {text || value, html}
        {"text/html", value} when is_binary(value) -> {text, html || value}
        _other -> {text, html}
      end
    end)
  end

  defp flatten_parts(payload) do
    parts = Map.get(payload, "parts", [])

    if parts == [] do
      [payload]
    else
      Enum.flat_map(parts, &flatten_parts/1)
    end
  end

  defp decode_base64url(nil), do: nil

  defp decode_base64url(data) do
    data
    |> pad_base64()
    |> Base.url_decode64()
    |> case do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end

  defp pad_base64(data) do
    case rem(String.length(data), 4) do
      0 -> data
      missing -> data <> String.duplicate("=", 4 - missing)
    end
  end

  defp html_to_text(nil), do: nil

  defp html_to_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_common_entities()
    |> String.trim()
  end

  defp decode_common_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp maybe_put_query(params, query) when query in [nil, ""], do: params
  defp maybe_put_query(params, query), do: [{"q", query} | params]

  defp parse_internal_date(nil), do: nil

  defp parse_internal_date(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, _rest} -> DateTime.from_unix(milliseconds, :millisecond) |> ok_or_nil()
      :error -> nil
    end
  end

  defp parse_internal_date(value) when is_integer(value) do
    DateTime.from_unix(value, :millisecond) |> ok_or_nil()
  end

  defp parse_internal_date(_value), do: nil

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_other), do: nil

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> clamp_limit(parsed)
      :error -> @default_limit
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_limit), do: @default_limit
end
