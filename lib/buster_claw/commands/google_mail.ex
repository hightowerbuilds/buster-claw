defmodule BusterClaw.Commands.Google.Mail do
  @moduledoc """
  Gmail command implementations: labels, search/read, sync, draft creation, send,
  and message mutation (modify/trash/delete).

  Account resolution funnels through
  `BusterClaw.Commands.Google.Accounts.with_google_account/2`. Each function keeps
  the canonical `{:ok, _} | {:error, reason}` contract and takes a single
  string-keyed args map.
  """

  import BusterClaw.Commands.Google.Accounts, only: [with_google_account: 2, truthy?: 1]

  alias BusterClaw.Google.{Gmail, GmailSync}

  def gmail_label_list(args \\ %{}) do
    with_google_account(args, fn account ->
      Gmail.labels(account)
    end)
  end

  def gmail_search(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)
      Gmail.search(account, query, limit: limit)
    end)
  end

  def gmail_read(args) do
    message_id = Map.get(args, "message_id") || Map.get(args, "id")

    if message_id in [nil, ""] do
      {:error, :missing_message_id}
    else
      with_google_account(args, fn account ->
        Gmail.read(account, message_id)
      end)
    end
  end

  def gmail_sync(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)

      GmailSync.sync(account,
        query: query,
        limit: limit,
        incremental: truthy?(Map.get(args, "incremental", false)),
        start_history_id: Map.get(args, "start_history_id")
      )
    end)
  end

  def gmail_draft_create(args) do
    with_google_account(args, fn account ->
      Gmail.create_draft(account, args)
    end)
  end

  def gmail_send(args) do
    if send_confirmed?(args) do
      with_google_account(args, fn account ->
        Gmail.send_message(account, args)
      end)
    else
      {:error, :missing_send_confirmation}
    end
  end

  def gmail_modify(args) do
    with_message_id(args, fn account, message_id ->
      Gmail.modify(account, message_id, args)
    end)
  end

  def gmail_trash(args) do
    with_message_id(args, fn account, message_id ->
      Gmail.trash(account, message_id)
    end)
  end

  def gmail_delete(args) do
    with_message_id(args, fn account, message_id ->
      Gmail.delete(account, message_id)
    end)
  end

  defp with_message_id(args, fun) do
    message_id = Map.get(args, "message_id") || Map.get(args, "id")

    if message_id in [nil, ""] do
      {:error, :missing_message_id}
    else
      with_google_account(args, fn account -> fun.(account, message_id) end)
    end
  end

  defp send_confirmed?(args) do
    Map.get(args, "confirm_send") in [true, "true", "send", "SEND"]
  end
end
