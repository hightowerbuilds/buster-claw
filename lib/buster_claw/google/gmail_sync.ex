defmodule BusterClaw.Google.GmailSync do
  @moduledoc "Sync Gmail messages into the local Library as raw markdown documents."

  alias BusterClaw.Google
  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Library
  alias BusterClaw.LocalTime

  @default_query "newer_than:7d"
  @default_limit 10

  def sync(%Account{} = account, opts \\ []) do
    if Keyword.get(opts, :incremental, false) do
      sync_incremental(account, opts)
    else
      sync_query(account, opts)
    end
  end

  def sync_incremental(%Account{} = account, opts \\ []) do
    start_history_id =
      opts |> Keyword.get(:start_history_id, account.last_seen_history_id) |> present_or_nil()

    if is_nil(start_history_id) do
      {:ok, full_sync_required_result(account, start_history_id, :missing_history_id)}
    else
      account
      |> history_pages(start_history_id, opts)
      |> case do
        {:ok, pages} ->
          sync_history_pages(account, start_history_id, pages, opts)

        {:error, {:google_api_error, 404, body}} ->
          {:ok, full_sync_required_result(account, start_history_id, :history_id_too_old, body)}

        error ->
          error
      end
    end
  end

  defp sync_query(%Account{} = account, opts) do
    query =
      opts |> Keyword.get(:query) |> present_or_nil() || account.default_query || @default_query

    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, search} <- Gmail.search(account, query, Keyword.put(opts, :limit, limit)) do
      results =
        Enum.map(search.messages, fn message ->
          sync_message(account, message.id, opts)
        end)

      documents = synced_documents(results)
      errors = sync_errors(results)
      synced_at = timestamp()

      account_attrs =
        %{"last_synced_at" => synced_at}
        |> maybe_put_history_id(results)

      with {:ok, updated_account} <- Google.update_account(account, account_attrs) do
        {:ok,
         %{
           account: Google.account_summary(updated_account),
           query: query,
           requested: length(search.messages),
           synced: length(documents),
           documents: documents,
           errors: errors,
           last_synced_at: synced_at,
           result_size_estimate: search.result_size_estimate,
           next_page_token: search.next_page_token
         }}
      end
    end
  end

  defp history_pages(%Account{} = account, start_history_id, opts) do
    fetch_history_page(account, start_history_id, nil, opts, [])
  end

  defp fetch_history_page(%Account{} = account, start_history_id, page_token, opts, pages) do
    opts =
      if page_token in [nil, ""] do
        opts
      else
        Keyword.put(opts, :page_token, page_token)
      end

    case Gmail.history(account, start_history_id, opts) do
      {:ok, page} ->
        pages = [page | pages]

        if page.next_page_token in [nil, ""] do
          {:ok, Enum.reverse(pages)}
        else
          fetch_history_page(account, start_history_id, page.next_page_token, opts, pages)
        end

      error ->
        error
    end
  end

  defp sync_history_pages(%Account{} = account, start_history_id, pages, opts) do
    message_ids = changed_message_ids(pages)

    results =
      Enum.map(message_ids, fn message_id ->
        sync_message(account, message_id, opts)
      end)

    documents = synced_documents(results)
    errors = sync_errors(results)
    synced_at = timestamp()
    history_id = latest_history_id(pages)

    account_attrs =
      %{"last_synced_at" => synced_at}
      |> maybe_put_response_history_id(history_id)

    with {:ok, updated_account} <- Google.update_account(account, account_attrs) do
      {:ok,
       %{
         mode: :incremental,
         account: Google.account_summary(updated_account),
         start_history_id: start_history_id,
         history_id: history_id,
         requested: length(message_ids),
         synced: length(documents),
         documents: documents,
         errors: errors,
         deleted_message_ids: deleted_message_ids(pages),
         history_records: Enum.sum(Enum.map(pages, &length(&1.history))),
         full_sync_required: false,
         full_sync_reason: nil,
         last_synced_at: synced_at
       }}
    end
  end

  defp sync_message(%Account{} = account, message_id, opts) do
    with {:ok, message} <- Gmail.read(account, message_id, opts),
         {:ok, document} <- save_message(account, message) do
      {:ok, document, message}
    end
  end

  defp save_message(%Account{} = account, message) do
    Library.save_raw_document(%{
      date: message_date(message),
      filename: "gmail-#{safe_message_id(message.id)}.md",
      source_url: source_url(account, message),
      name: message.subject || "(no subject)",
      tags: ["gmail", "google-workspace" | message.label_ids],
      content: message_markdown(account, message),
      fetched_at: timestamp()
    })
  end

  defp message_markdown(%Account{} = account, message) do
    metadata =
      [
        {"Account", account.email},
        {"From", message.from},
        {"To", message.to},
        {"Date", message.date},
        {"Gmail Message ID", message.id},
        {"Thread ID", message.thread_id},
        {"Labels", Enum.join(message.label_ids, ", ")}
      ]
      |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
      |> Enum.map_join("\n", fn {label, value} -> "- #{label}: #{value}" end)

    body = message.body_text || message.snippet || ""
    title = message.subject || "(no subject)"

    """
    # #{title}

    #{metadata}

    #{body}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp synced_documents(results) do
    Enum.flat_map(results, fn
      {:ok, document, _message} -> [document]
      _other -> []
    end)
  end

  defp sync_errors(results) do
    Enum.flat_map(results, fn
      {:ok, _document, _message} -> []
      {:error, reason} -> [reason]
    end)
  end

  defp maybe_put_history_id(attrs, results) do
    history_id =
      Enum.find_value(results, fn
        {:ok, _document, message} -> message.history_id
        _other -> nil
      end)

    if history_id in [nil, ""] do
      attrs
    else
      Map.put(attrs, "last_seen_history_id", history_id)
    end
  end

  defp maybe_put_response_history_id(attrs, history_id) when history_id in [nil, ""], do: attrs

  defp maybe_put_response_history_id(attrs, history_id) do
    Map.put(attrs, "last_seen_history_id", history_id)
  end

  defp changed_message_ids(pages) do
    deleted_ids = pages |> deleted_message_ids() |> MapSet.new()

    pages
    |> Enum.flat_map(& &1.message_ids)
    |> Enum.reject(&MapSet.member?(deleted_ids, &1))
    |> Enum.uniq()
  end

  defp deleted_message_ids(pages) do
    pages
    |> Enum.flat_map(& &1.deleted_message_ids)
    |> Enum.uniq()
  end

  defp latest_history_id(pages) do
    pages
    |> Enum.reverse()
    |> Enum.find_value(&present_or_nil(&1.history_id))
  end

  defp full_sync_required_result(account, start_history_id, reason, response \\ nil) do
    %{
      mode: :incremental,
      account: Google.account_summary(account),
      start_history_id: start_history_id,
      history_id: nil,
      requested: 0,
      synced: 0,
      documents: [],
      errors: [],
      deleted_message_ids: [],
      history_records: 0,
      full_sync_required: true,
      full_sync_reason: reason,
      google_response: response,
      last_synced_at: account.last_synced_at
    }
  end

  defp message_date(%{internal_date: %DateTime{} = date_time}), do: DateTime.to_date(date_time)
  defp message_date(_message), do: LocalTime.today()

  defp source_url(%Account{} = account, message) do
    "gmail://#{URI.encode_www_form(account.email)}/messages/#{URI.encode_www_form(message.id)}"
  end

  defp safe_message_id(message_id) do
    message_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp present_or_nil(value) when value in [nil, ""], do: nil
  defp present_or_nil(value), do: value
end
