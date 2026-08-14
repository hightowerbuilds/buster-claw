defmodule BusterClaw.Google.Gmail.Parser do
  @moduledoc """
  Turns raw Gmail API JSON into the plain maps the rest of the app consumes.

  Owns the inbound half of the Gmail seam: the message/label/draft/history
  builders, MIME part traversal (`multipart/*` payloads are a tree — the body
  can be at any depth), base64url body decoding, the HTML-to-text fallback used
  when a message carries no `text/plain` part, and `internalDate` parsing.

  Pure and total by design: it performs no HTTP and never raises on shape.
  Anything missing from a response comes back as `nil` or `[]` rather than
  crashing a caller mid-`with`, because Gmail omits fields freely depending on
  the `format` requested (`metadata` responses have no bodies at all).
  """

  @doc "Build the full message map from a `format=full` messages.get response."
  def parse_message(body) do
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

  @doc "Build the headers-only summary used by search results and modify/trash."
  def message_summary(body) do
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

  @doc "Build a label map from a labels.list entry."
  def label_summary(label) do
    %{
      id: Map.get(label, "id"),
      name: Map.get(label, "name"),
      type: Map.get(label, "type"),
      message_list_visibility: Map.get(label, "messageListVisibility"),
      label_list_visibility: Map.get(label, "labelListVisibility")
    }
  end

  @doc "Build a draft map from a drafts.create response."
  def draft_summary(body) do
    %{
      id: Map.get(body, "id"),
      message_id: get_in(body, ["message", "id"]),
      thread_id: get_in(body, ["message", "threadId"]),
      raw: body
    }
  end

  @doc "Build the map returned after messages.send / messages.trash."
  def sent_message_summary(body) do
    %{
      id: Map.get(body, "id"),
      thread_id: Map.get(body, "threadId"),
      label_ids: Map.get(body, "labelIds", []),
      raw: body
    }
  end

  @doc """
  Build the history map from a history.list response, splitting the changed and
  deleted message ids (a message deleted within the same window is excluded from
  the changed set — there is nothing left to fetch).
  """
  def history_summary(body) do
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
end
