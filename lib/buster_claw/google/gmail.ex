defmodule BusterClaw.Google.Gmail do
  @moduledoc """
  Gmail read/search/draft/send helpers for connected Google Workspace accounts.

  This module is the Gmail API surface: which endpoint each verb hits, what
  query parameters it carries, and how concurrent fan-out and paging limits
  behave. Transport, auth and retry live in `BusterClaw.Google.Client`; the two
  halves of message shaping live beside this file —
  `BusterClaw.Google.Gmail.Mime` composes outbound messages (and owns the
  attachment fence), `BusterClaw.Google.Gmail.Parser` reads inbound responses.
  """

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client
  alias BusterClaw.Google.Gmail.Mime
  alias BusterClaw.Google.Gmail.Parser

  @default_limit 10
  @max_limit 50
  @default_history_limit 100
  @max_history_limit 500
  @summary_concurrency 5

  def labels(%Account{} = account, opts \\ []) do
    with {:ok, body} <- Client.get_json(account, "users/me/labels", opts) do
      labels =
        body
        |> Map.get("labels", [])
        |> Enum.map(&Parser.label_summary/1)

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

    # Refresh once up front so the concurrent `fetch_summary` fan-out below shares
    # a single fresh token instead of each task independently refreshing an
    # expired one (a refresh stampede + racing account writes).
    with {:ok, account} <- Client.ensure_fresh_token(account, opts),
         {:ok, body} <-
           Client.get_json(account, "users/me/messages", Keyword.put(opts, :params, params)) do
      # Each id needs its own metadata GET (an independent HTTP round trip), so
      # fan them out concurrently rather than mapping sequentially. `ordered: true`
      # preserves the result order; `timeout: :infinity` defers to Req's own
      # receive timeout. Mirrors GmailSync.sync_messages.
      messages =
        body
        |> Map.get("messages", [])
        |> Enum.take(limit)
        |> Task.async_stream(
          fn message -> fetch_summary(account, message, opts) end,
          max_concurrency: Keyword.get(opts, :max_concurrency, @summary_concurrency),
          ordered: true,
          timeout: :infinity
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:summary_task_exit, reason}}
        end)
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

  # messages.list only — returns ids plus pagination, with no per-message
  # metadata GETs. `search/3` is for callers that need rendered summaries; the
  # sync path only needs ids (it re-fetches each with `format=full`), so this
  # avoids a wasted metadata round trip per result.
  def list_ids(%Account{} = account, query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    params =
      [
        {"maxResults", Integer.to_string(limit)}
      ]
      |> maybe_put_query(query)

    with {:ok, body} <-
           Client.get_json(account, "users/me/messages", Keyword.put(opts, :params, params)) do
      ids =
        body
        |> Map.get("messages", [])
        |> Enum.take(limit)
        |> Enum.map(&Map.get(&1, "id"))
        |> Enum.reject(&(&1 in [nil, ""]))

      {:ok,
       %{
         message_ids: ids,
         result_size_estimate: Map.get(body, "resultSizeEstimate", length(ids)),
         next_page_token: Map.get(body, "nextPageToken")
       }}
    end
  end

  def read(%Account{} = account, message_id, opts \\ []) do
    path = "users/me/messages/#{URI.encode_www_form(to_string(message_id))}"
    opts = Keyword.put(opts, :params, [{"format", "full"}])

    with {:ok, body} <- Client.get_json(account, path, opts) do
      {:ok, Parser.parse_message(body)}
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
      {:ok, Parser.history_summary(body)}
    end
  end

  def create_draft(%Account{} = account, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, mime} <- Mime.message_mime(attrs),
         {:ok, body} <-
           Client.post_json(
             account,
             "users/me/drafts",
             %{"message" => %{"raw" => Base.url_encode64(mime, padding: false)}},
             opts
           ) do
      {:ok, Parser.draft_summary(body)}
    end
  end

  def send_message(%Account{} = account, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, mime} <- Mime.message_mime(attrs),
         {:ok, body} <-
           Client.post_json(
             account,
             "users/me/messages/send",
             send_payload(mime, attrs),
             opts
           ) do
      {:ok, Parser.sent_message_summary(body)}
    end
  end

  @doc """
  Add and/or remove labels on a message (`messages.modify`). Archive = remove
  `INBOX`; mark read = remove `UNREAD`. `attrs` accepts `add`/`remove` lists of
  label ids (string or list).
  """
  def modify(%Account{} = account, message_id, attrs, opts \\ []) when is_map(attrs) do
    path = "users/me/messages/#{URI.encode_www_form(to_string(message_id))}/modify"

    body = %{
      "addLabelIds" => label_id_list(attrs, ["add", "add_label_ids"]),
      "removeLabelIds" => label_id_list(attrs, ["remove", "remove_label_ids"])
    }

    with {:ok, body} <- Client.post_json(account, path, body, opts) do
      {:ok, Parser.message_summary(body)}
    end
  end

  @doc "Move a message to the trash (recoverable) via `messages.trash`."
  def trash(%Account{} = account, message_id, opts \\ []) do
    path = "users/me/messages/#{URI.encode_www_form(to_string(message_id))}/trash"

    with {:ok, body} <- Client.post_json(account, path, %{}, opts) do
      {:ok, Parser.sent_message_summary(body)}
    end
  end

  @doc "Permanently delete a message (irreversible) via `messages.delete`."
  def delete(%Account{} = account, message_id, opts \\ []) do
    path = "users/me/messages/#{URI.encode_www_form(to_string(message_id))}"

    with {:ok, _} <- Client.delete(account, path, opts) do
      {:ok, %{id: to_string(message_id), deleted: true}}
    end
  end

  defp label_id_list(attrs, keys) do
    keys
    |> Enum.find_value([], fn key -> Mime.get_attr(attrs, key) end)
    |> normalize_label_ids()
  end

  defp normalize_label_ids(nil), do: []
  defp normalize_label_ids(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp normalize_label_ids(value) when is_binary(value),
    do: String.split(value, ~r/[,\s]+/, trim: true)

  defp normalize_label_ids(value), do: [to_string(value)]

  # Including `threadId` makes Gmail file the sent message into the original
  # conversation (alongside the In-Reply-To / References headers from the MIME).
  defp send_payload(mime, attrs) do
    base = %{"raw" => Base.url_encode64(mime, padding: false)}

    case Mime.header_value(Mime.get_attr(attrs, "thread_id")) do
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
      {:ok, Parser.message_summary(body)}
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
