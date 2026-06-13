defmodule BusterClaw.Google.CalendarSync do
  @moduledoc "One-way Google Calendar import into Buster Claw calendar events."

  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Google
  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Calendar

  @default_calendar_id "primary"
  @default_days_ahead 90

  def sync(%Account{} = account, opts \\ []) do
    calendar_id = Keyword.get(opts, :calendar_id, @default_calendar_id)
    days_ahead = Keyword.get(opts, :days_ahead, @default_days_ahead)

    sync_token =
      if Keyword.get(opts, :force_full?, false), do: nil, else: sync_token(account, calendar_id)

    account
    |> calendar_pages(calendar_id, days_ahead, sync_token, opts)
    |> case do
      {:ok, result} ->
        with {:ok, synced} <- sync_events(account, calendar_id, result),
             {:ok, updated_account} <- store_sync_result(account, calendar_id, result) do
          {:ok,
           %{
             account: Google.account_summary(updated_account),
             calendar_id: calendar_id,
             mode: sync_mode(result),
             imported: length(synced.events),
             created: synced.created,
             updated: synced.updated,
             deleted: synced.deleted,
             events: synced.events,
             deleted_events: synced.deleted_events,
             time_min: result.time_min,
             time_max: result.time_max,
             sync_token: result.sync_token,
             next_sync_token: result.next_sync_token,
             next_page_token: result.next_page_token,
             pages: result.pages
           }}
        end

      {:error, {:sync_token_invalid, info}} ->
        handle_invalid_sync_token(account, calendar_id, info)

      other ->
        other
    end
  end

  defp calendar_pages(%Account{} = account, calendar_id, days_ahead, sync_token, opts) do
    fetch_calendar_page(account, calendar_id, days_ahead, sync_token, nil, opts, [])
  end

  defp fetch_calendar_page(account, calendar_id, days_ahead, sync_token, page_token, opts, pages) do
    request_opts =
      request_opts(calendar_id, days_ahead, sync_token, opts)
      |> maybe_put_page_token(page_token)

    case Calendar.events(account, request_opts) do
      {:ok, page} ->
        pages = [page | pages]

        if page.next_page_token in [nil, ""] do
          {:ok, merge_pages(Enum.reverse(pages))}
        else
          fetch_calendar_page(
            account,
            calendar_id,
            days_ahead,
            sync_token,
            page.next_page_token,
            opts,
            pages
          )
        end

      error ->
        error
    end
  end

  defp maybe_put_page_token(opts, page_token) when page_token in [nil, ""], do: opts
  defp maybe_put_page_token(opts, page_token), do: Keyword.put(opts, :page_token, page_token)

  defp merge_pages([first | _rest] = pages) do
    last = List.last(pages)

    first
    |> Map.put(:events, Enum.flat_map(pages, & &1.events))
    |> Map.put(:next_page_token, last.next_page_token)
    |> Map.put(:next_sync_token, last.next_sync_token)
    |> Map.put(:pages, length(pages))
  end

  defp request_opts(calendar_id, days_ahead, nil, opts) do
    [
      calendar_id: calendar_id,
      days_ahead: days_ahead,
      req_options: Keyword.get(opts, :req_options, [])
    ]
  end

  defp request_opts(calendar_id, _days_ahead, sync_token, opts) do
    [
      calendar_id: calendar_id,
      sync_token: sync_token,
      req_options: Keyword.get(opts, :req_options, [])
    ]
  end

  defp sync_events(%Account{} = account, calendar_id, %{incremental?: true} = result) do
    sync_incremental_events(account, calendar_id, result.events)
  end

  defp sync_events(%Account{} = account, calendar_id, result) do
    AppCalendar.sync_external_events(
      event_prefix(account, calendar_id),
      Enum.flat_map(result.events, &event_attrs(account, calendar_id, &1))
    )
  end

  defp sync_incremental_events(%Account{} = account, calendar_id, google_events) do
    attrs_list =
      google_events
      |> Enum.reject(&cancelled?/1)
      |> Enum.flat_map(&event_attrs(account, calendar_id, &1))

    # One query for the rows this batch may touch (upserts + deletes), keyed by
    # event_id, so the loops below decide create/update/delete in memory.
    cancelled_event_ids =
      google_events
      |> Enum.filter(&cancelled?/1)
      |> Enum.flat_map(fn ge ->
        case google_event_id(ge) do
          id when is_binary(id) -> [event_prefix(account, calendar_id) <> event_key(id)]
          _ -> []
        end
      end)

    touched_event_ids = Enum.map(attrs_list, &event_id!/1) ++ cancelled_event_ids
    existing_by_id = AppCalendar.events_by_event_ids(touched_event_ids)

    with {:ok, {created, updated, events}} <- upsert_event_attrs(attrs_list, existing_by_id),
         {:ok, deleted_events} <-
           delete_cancelled_events(account, calendar_id, google_events, existing_by_id) do
      {:ok,
       %{
         created: created,
         updated: updated,
         deleted: length(deleted_events),
         events: events,
         deleted_events: deleted_events
       }}
    end
  end

  defp upsert_event_attrs(attrs_list, existing_by_id) do
    Enum.reduce_while(attrs_list, {:ok, {0, 0, []}}, fn attrs,
                                                        {:ok, {created, updated, events}} ->
      case upsert_event(attrs, existing_by_id) do
        {:created, event} -> {:cont, {:ok, {created + 1, updated, [event | events]}}}
        {:updated, event} -> {:cont, {:ok, {created, updated + 1, [event | events]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {created, updated, events}} -> {:ok, {created, updated, Enum.reverse(events)}}
      other -> other
    end
  end

  defp upsert_event(attrs, existing_by_id) do
    event_id = event_id!(attrs)

    case Map.get(existing_by_id, event_id) do
      nil ->
        with {:ok, event} <- AppCalendar.create_event(attrs), do: {:created, event}

      event ->
        with {:ok, event} <- AppCalendar.update_event(event, attrs), do: {:updated, event}
    end
  end

  defp delete_cancelled_events(%Account{} = account, calendar_id, google_events, existing_by_id) do
    google_events
    |> Enum.filter(&cancelled?/1)
    |> Enum.reduce_while({:ok, []}, fn google_event, {:ok, deleted_events} ->
      case delete_cancelled_event(account, calendar_id, google_event, existing_by_id) do
        {:ok, nil} -> {:cont, {:ok, deleted_events}}
        {:ok, deleted_event} -> {:cont, {:ok, [deleted_event | deleted_events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, deleted_events} -> {:ok, Enum.reverse(deleted_events)}
      other -> other
    end
  end

  defp delete_cancelled_event(%Account{} = account, calendar_id, google_event, existing_by_id) do
    with id when is_binary(id) <- google_event_id(google_event),
         event_id <- event_prefix(account, calendar_id) <> event_key(id),
         event when not is_nil(event) <- Map.get(existing_by_id, event_id) do
      AppCalendar.delete_event(event)
    else
      _other -> {:ok, nil}
    end
  end

  defp event_attrs(%Account{} = account, calendar_id, google_event) do
    with id when is_binary(id) <- google_event_id(google_event) do
      start = google_event.start || %{date: nil, time: nil, all_day?: true}
      finish = google_event.end || %{time: nil}
      title = google_event.summary || "(no title)"
      notes = notes(account, calendar_id, google_event)

      if start.date do
        [
          %{
            event_id: event_prefix(account, calendar_id) <> event_key(id),
            date: start.date,
            start_time: start.time,
            end_time: finish.time,
            title: title,
            notes: notes,
            color: "work",
            frequency: nil,
            recur_until: nil
          }
        ]
      else
        []
      end
    else
      _other -> []
    end
  end

  defp notes(%Account{} = account, calendar_id, google_event) do
    [
      google_event.description,
      "Google Calendar",
      "Account: #{account.email}",
      "Calendar: #{calendar_id}",
      "Google Event ID: #{google_event.id}",
      google_event.location && "Location: #{google_event.location}",
      google_event.html_link && "Link: #{google_event.html_link}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp event_prefix(%Account{} = account, calendar_id) do
    "google-calendar:#{account.id}:#{calendar_key(calendar_id)}:"
  end

  defp calendar_key(value), do: value |> to_string() |> URI.encode_www_form()
  defp event_key(value), do: value |> to_string() |> URI.encode_www_form()

  defp event_id!(attrs), do: Map.get(attrs, :event_id) || Map.fetch!(attrs, "event_id")

  defp google_event_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp google_event_id(_google_event), do: nil

  defp cancelled?(%{status: "cancelled"}), do: true
  defp cancelled?(_google_event), do: false

  defp store_sync_result(%Account{} = account, calendar_id, result) do
    attrs = %{"last_synced_at" => timestamp()}

    attrs =
      cond do
        present?(result.next_sync_token) ->
          Map.put(
            attrs,
            "calendar_sync_tokens",
            put_sync_token(account.calendar_sync_tokens, calendar_id, result.next_sync_token)
          )

        result.incremental? ->
          attrs

        true ->
          Map.put(
            attrs,
            "calendar_sync_tokens",
            delete_sync_token(account.calendar_sync_tokens, calendar_id)
          )
      end

    Google.update_account(account, attrs)
  end

  defp handle_invalid_sync_token(%Account{} = account, calendar_id, info) do
    with {:ok, _updated_account} <-
           Google.update_account(account, %{
             "calendar_sync_tokens" =>
               delete_sync_token(account.calendar_sync_tokens, calendar_id)
           }) do
      {:error,
       {:calendar_sync_token_invalid,
        info
        |> Map.put(:account_id, account.id)
        |> Map.put(:calendar_id, calendar_id)
        |> Map.put(:full_sync_required, true)}}
    end
  end

  defp sync_token(%Account{} = account, calendar_id) do
    account.calendar_sync_tokens
    |> normalize_tokens()
    |> Map.get(sync_token_key(calendar_id))
    |> blank_to_nil()
  end

  defp put_sync_token(tokens, calendar_id, sync_token) do
    tokens
    |> normalize_tokens()
    |> Map.put(sync_token_key(calendar_id), sync_token)
  end

  defp delete_sync_token(tokens, calendar_id) do
    tokens
    |> normalize_tokens()
    |> Map.delete(sync_token_key(calendar_id))
  end

  defp normalize_tokens(tokens) when is_map(tokens), do: tokens
  defp normalize_tokens(_tokens), do: %{}

  defp sync_token_key(calendar_id), do: to_string(calendar_id)

  defp sync_mode(%{incremental?: true}), do: :incremental
  defp sync_mode(_result), do: :full

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
