defmodule BusterClaw.Commands.Google.Docs do
  @moduledoc """
  Google Docs/Sheets/Slides command implementations: document, spreadsheet, and
  presentation reads plus the `batchUpdate` writes.

  Account resolution and the generic argument validators (`with_google_account`,
  `with_required`, `with_requests`) come from
  `BusterClaw.Commands.Google.Accounts`; the Sheets range validators are private
  here since only this module needs them. The `BusterClaw.Commands.Google` facade
  delegates to these functions so dispatch, policy, and rate-limiting still funnel
  through the single `Commands.call/2` choke point.
  """

  import BusterClaw.Commands.Google.Accounts,
    only: [with_google_account: 2, with_required: 4, with_requests: 4]

  alias BusterClaw.Google.{Docs, Sheets, Slides}

  def docs_get(args) do
    with_required(args, "document_id", :missing_document_id, fn account, document_id ->
      Docs.get(account, document_id)
    end)
  end

  def docs_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      Docs.create(account, title)
    end)
  end

  def docs_batch_update(args) do
    with_requests(args, "document_id", :missing_document_id, fn account, document_id, requests ->
      Docs.batch_update(account, document_id, requests)
    end)
  end

  def sheets_get(args) do
    with_required(args, "spreadsheet_id", :missing_spreadsheet_id, fn account, id ->
      Sheets.get(account, id)
    end)
  end

  def sheets_get_values(args) do
    with_range(args, fn account, id, range ->
      Sheets.get_values(account, id, range)
    end)
  end

  def sheets_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      Sheets.create(account, title)
    end)
  end

  def sheets_update_values(args) do
    with_range_values(args, fn account, id, range, values ->
      Sheets.update_values(account, id, range, values)
    end)
  end

  def sheets_append_values(args) do
    with_range_values(args, fn account, id, range, values ->
      Sheets.append_values(account, id, range, values)
    end)
  end

  def sheets_clear_values(args) do
    with_range(args, fn account, id, range ->
      Sheets.clear_values(account, id, range)
    end)
  end

  def sheets_batch_update(args) do
    with_requests(args, "spreadsheet_id", :missing_spreadsheet_id, fn account, id, requests ->
      Sheets.batch_update(account, id, requests)
    end)
  end

  def slides_get(args) do
    with_required(args, "presentation_id", :missing_presentation_id, fn account, id ->
      Slides.get(account, id)
    end)
  end

  def slides_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      Slides.create(account, title)
    end)
  end

  def slides_batch_update(args) do
    with_requests(args, "presentation_id", :missing_presentation_id, fn account, id, requests ->
      Slides.batch_update(account, id, requests)
    end)
  end

  # Require spreadsheet_id + range (Sheets reads/clear).
  defp with_range(args, fun) do
    id = Map.get(args, "spreadsheet_id")
    range = Map.get(args, "range")

    cond do
      id in [nil, ""] -> {:error, :missing_spreadsheet_id}
      range in [nil, ""] -> {:error, :missing_range}
      true -> with_google_account(args, fn account -> fun.(account, id, range) end)
    end
  end

  # Require spreadsheet_id + range + a 2-D values list (Sheets writes).
  defp with_range_values(args, fun) do
    values = Map.get(args, "values")

    with_range(args, fn account, id, range ->
      if is_list(values), do: fun.(account, id, range, values), else: {:error, :missing_values}
    end)
  end
end
