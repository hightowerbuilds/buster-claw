defmodule BusterClaw.Google.Gmail do
  @moduledoc "Gmail read/search/draft/send helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @default_limit 10
  @max_limit 50
  @default_history_limit 100
  @max_history_limit 500

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

  def history(%Account{} = account, start_history_id, opts \\ []) do
    params =
      [
        {"startHistoryId", to_string(start_history_id)},
        {"maxResults", opts |> history_limit() |> Integer.to_string()}
      ]
      |> maybe_put_page_token(Keyword.get(opts, :page_token))
      |> maybe_put_label_id(Keyword.get(opts, :label_id))
      |> maybe_put_history_types(Keyword.get(opts, :history_types, []))

    with {:ok, body} <-
           Client.get_json(account, "users/me/history", Keyword.put(opts, :params, params)) do
      {:ok, history_summary(body)}
    end
  end

  def create_draft(%Account{} = account, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, mime} <- message_mime(attrs),
         {:ok, body} <-
           Client.post_json(
             account,
             "users/me/drafts",
             %{"message" => %{"raw" => Base.url_encode64(mime, padding: false)}},
             opts
           ) do
      {:ok, draft_summary(body)}
    end
  end

  def send_message(%Account{} = account, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, mime} <- message_mime(attrs),
         {:ok, body} <-
           Client.post_json(
             account,
             "users/me/messages/send",
             send_payload(mime, attrs),
             opts
           ) do
      {:ok, sent_message_summary(body)}
    end
  end

  # Including `threadId` makes Gmail file the sent message into the original
  # conversation (alongside the In-Reply-To / References headers from the MIME).
  defp send_payload(mime, attrs) do
    base = %{"raw" => Base.url_encode64(mime, padding: false)}

    case header_value(get_attr(attrs, "thread_id")) do
      "" -> base
      thread_id -> Map.put(base, "threadId", thread_id)
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
      # The RFC 5322 Message-ID header (distinct from the Gmail API `id`); used as
      # the In-Reply-To / References target when replying so the reply threads.
      message_id_header: Map.get(headers, "message-id"),
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

  defp draft_summary(body) do
    %{
      id: Map.get(body, "id"),
      message_id: get_in(body, ["message", "id"]),
      thread_id: get_in(body, ["message", "threadId"]),
      raw: body
    }
  end

  defp sent_message_summary(body) do
    %{
      id: Map.get(body, "id"),
      thread_id: Map.get(body, "threadId"),
      label_ids: Map.get(body, "labelIds", []),
      raw: body
    }
  end

  defp history_summary(body) do
    history = Map.get(body, "history", [])

    deleted_message_ids =
      history |> Enum.flat_map(&history_event_message_ids(&1, "messagesDeleted")) |> unique_ids()

    message_ids =
      history
      |> Enum.flat_map(&history_changed_message_ids/1)
      |> unique_ids()
      |> Enum.reject(&(&1 in deleted_message_ids))

    %{
      history: history,
      history_id: Map.get(body, "historyId"),
      message_ids: message_ids,
      deleted_message_ids: deleted_message_ids,
      next_page_token: Map.get(body, "nextPageToken"),
      raw: body
    }
  end

  defp history_changed_message_ids(entry) do
    history_message_ids(entry, "messages") ++
      history_event_message_ids(entry, "messagesAdded") ++
      history_event_message_ids(entry, "labelsAdded") ++
      history_event_message_ids(entry, "labelsRemoved")
  end

  defp history_message_ids(entry, key) do
    entry
    |> Map.get(key, [])
    |> Enum.map(&Map.get(&1, "id"))
  end

  defp history_event_message_ids(entry, key) do
    entry
    |> Map.get(key, [])
    |> Enum.map(fn event ->
      get_in(event, ["message", "id"]) || Map.get(event, "id")
    end)
  end

  defp unique_ids(ids) do
    ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp message_mime(attrs) do
    with {:ok, to} <- required_header(attrs, "to", :missing_recipient),
         {:ok, subject} <- required_header(attrs, "subject", :missing_subject),
         {:ok, body} <- required_body(attrs) do
      headers =
        [
          {"To", to},
          optional_header("Cc", attrs, "cc"),
          optional_header("Bcc", attrs, "bcc"),
          optional_header("In-Reply-To", attrs, "in_reply_to"),
          optional_header("References", attrs, "references"),
          {"Subject", subject},
          {"MIME-Version", "1.0"},
          {"Content-Type", ~s(text/plain; charset="UTF-8")}
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join("\r\n", fn {key, value} -> "#{key}: #{value}" end)

      {:ok, headers <> "\r\n\r\n" <> body}
    end
  end

  defp required_header(attrs, key, error) do
    case header_value(get_attr(attrs, key)) do
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp optional_header(label, attrs, key) do
    case header_value(get_attr(attrs, key)) do
      "" -> nil
      value -> {label, value}
    end
  end

  defp required_body(attrs) do
    case get_attr(attrs, "body") do
      value when value in [nil, ""] -> {:error, :missing_body}
      value -> {:ok, to_string(value)}
    end
  end

  defp get_attr(attrs, key) when is_binary(key) do
    case key do
      "to" ->
        Map.get(attrs, "to") || Map.get(attrs, :to) || Map.get(attrs, "recipient") ||
          Map.get(attrs, :recipient)

      "cc" ->
        Map.get(attrs, "cc") || Map.get(attrs, :cc)

      "bcc" ->
        Map.get(attrs, "bcc") || Map.get(attrs, :bcc)

      "subject" ->
        Map.get(attrs, "subject") || Map.get(attrs, :subject)

      "body" ->
        Map.get(attrs, "body") || Map.get(attrs, :body)

      "in_reply_to" ->
        Map.get(attrs, "in_reply_to") || Map.get(attrs, :in_reply_to)

      "references" ->
        Map.get(attrs, "references") || Map.get(attrs, :references)

      "thread_id" ->
        Map.get(attrs, "thread_id") || Map.get(attrs, :thread_id)

      _other ->
        Map.get(attrs, key)
    end
  end

  defp header_value(nil), do: ""

  defp header_value(values) when is_list(values) do
    values
    |> Enum.map(&header_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp header_value(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
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

  defp maybe_put_page_token(params, token) when token in [nil, ""], do: params
  defp maybe_put_page_token(params, token), do: [{"pageToken", token} | params]

  defp maybe_put_label_id(params, label_id) when label_id in [nil, ""], do: params
  defp maybe_put_label_id(params, label_id), do: [{"labelId", label_id} | params]

  defp maybe_put_history_types(params, history_types) do
    history_types
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reduce(params, fn history_type, acc ->
      [{"historyTypes", to_string(history_type)} | acc]
    end)
  end

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

  defp history_limit(opts) do
    opts
    |> Keyword.get(:history_limit, Keyword.get(opts, :max_results, @default_history_limit))
    |> clamp_history_limit()
  end

  defp clamp_history_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> clamp_history_limit(parsed)
      :error -> @default_history_limit
    end
  end

  defp clamp_history_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@max_history_limit)

  defp clamp_history_limit(_limit), do: @default_history_limit
end
