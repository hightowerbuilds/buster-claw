defmodule BusterClaw.Google.GmailSync do
  @moduledoc "Sync Gmail messages into the local Library as raw markdown documents."

  alias BusterClaw.Google
  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Library

  @default_query "newer_than:7d"
  @default_limit 10

  def sync(%Account{} = account, opts \\ []) do
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

  defp message_date(%{internal_date: %DateTime{} = date_time}), do: DateTime.to_date(date_time)
  defp message_date(_message), do: Date.utc_today()

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
