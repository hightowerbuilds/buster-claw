defmodule BusterClaw.Google.Calendar do
  @moduledoc "Google Calendar read helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client
  alias BusterClaw.LocalTime

  @calendar_base_url "https://www.googleapis.com/calendar/v3"
  @default_days_ahead 90
  @default_max_results 250

  def events(%Account{} = account, opts \\ []) do
    calendar_id = Keyword.get(opts, :calendar_id, "primary")
    sync_token = opts |> Keyword.get(:sync_token) |> blank_to_nil()
    {time_min, time_max} = sync_time_window(sync_token, opts)
    params = event_params(opts, sync_token, time_min, time_max)

    path = "calendars/#{URI.encode_www_form(calendar_id)}/events"

    opts =
      opts
      |> Keyword.put(:base_url, @calendar_base_url)
      |> Keyword.put(:params, params)

    case Client.get_json(account, path, opts) do
      {:ok, body} ->
        incremental? = not is_nil(sync_token)

        events =
          body
          |> Map.get("items", [])
          |> maybe_reject_cancelled(incremental?)
          |> Enum.map(&event_summary/1)

        {:ok,
         %{
           calendar_id: calendar_id,
           incremental?: incremental?,
           sync_token: sync_token,
           time_min: time_min,
           time_max: time_max,
           events: events,
           next_page_token: Map.get(body, "nextPageToken"),
           next_sync_token: Map.get(body, "nextSyncToken")
         }}

      {:error, {:google_api_error, 410, body}} when is_binary(sync_token) ->
        {:error,
         {:sync_token_invalid,
          %{calendar_id: calendar_id, status: 410, reason: error_reason(body)}}}

      other ->
        other
    end
  end

  defp event_params(opts, nil, time_min, time_max) do
    [
      {"singleEvents", "true"},
      {"showDeleted", "true"},
      {"orderBy", "startTime"},
      {"maxResults", opts |> Keyword.get(:max_results, @default_max_results) |> to_string()},
      {"timeMin", DateTime.to_iso8601(time_min)},
      {"timeMax", DateTime.to_iso8601(time_max)}
    ]
    |> maybe_put_page_token(Keyword.get(opts, :page_token))
  end

  defp event_params(opts, sync_token, _time_min, _time_max) do
    [
      {"singleEvents", "true"},
      {"showDeleted", "true"},
      {"maxResults", opts |> Keyword.get(:max_results, @default_max_results) |> to_string()},
      {"syncToken", sync_token}
    ]
    |> maybe_put_page_token(Keyword.get(opts, :page_token))
  end

  defp maybe_put_page_token(params, page_token) when page_token in [nil, ""], do: params
  defp maybe_put_page_token(params, page_token), do: [{"pageToken", page_token} | params]

  defp sync_time_window(nil, opts), do: time_window(opts)
  defp sync_time_window(_sync_token, _opts), do: {nil, nil}

  defp maybe_reject_cancelled(events, true), do: events
  defp maybe_reject_cancelled(events, false), do: Enum.reject(events, &cancelled?/1)

  defp cancelled?(event), do: Map.get(event, "status") == "cancelled"

  defp error_reason(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_reason(%{"error" => error}) when is_binary(error), do: error
  defp error_reason(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp error_reason(_body), do: "Google Calendar sync token expired or was invalidated"

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp event_summary(event) do
    start = event_time(Map.get(event, "start", %{}))
    finish = event_time(Map.get(event, "end", %{}))

    %{
      id: Map.get(event, "id"),
      recurring_event_id: Map.get(event, "recurringEventId"),
      status: Map.get(event, "status"),
      html_link: Map.get(event, "htmlLink"),
      summary: Map.get(event, "summary"),
      description: Map.get(event, "description"),
      location: Map.get(event, "location"),
      start: start,
      end: finish,
      raw: event
    }
  end

  defp event_time(%{"date" => date}) do
    case Date.from_iso8601(date) do
      {:ok, date} -> %{date: date, date_time: nil, time: nil, all_day?: true}
      _other -> %{date: nil, date_time: nil, time: nil, all_day?: true}
    end
  end

  defp event_time(%{"dateTime" => date_time}) do
    case parse_wall_datetime(date_time) do
      {%Date{} = date, %Time{} = time} ->
        %{date: date, date_time: date_time, time: time, all_day?: false}

      nil ->
        %{date: nil, date_time: nil, time: nil, all_day?: false}
    end
  end

  defp event_time(_other), do: %{date: nil, date_time: nil, time: nil, all_day?: true}

  defp parse_wall_datetime(value) when is_binary(value) do
    value
    |> String.slice(0, 19)
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive} ->
        {NaiveDateTime.to_date(naive), naive |> NaiveDateTime.to_time() |> Time.truncate(:second)}

      {:error, _reason} ->
        nil
    end
  end

  defp parse_wall_datetime(_value), do: nil

  defp time_window(opts) do
    today = LocalTime.today()
    days_ahead = parse_integer(Keyword.get(opts, :days_ahead), @default_days_ahead)

    time_min =
      opts
      |> Keyword.get(:time_min)
      |> parse_boundary(:start)
      |> Kernel.||(today |> DateTime.new!(~T[00:00:00], "Etc/UTC"))

    time_max =
      opts
      |> Keyword.get(:time_max)
      |> parse_boundary(:end)
      |> Kernel.||(today |> Date.add(days_ahead) |> DateTime.new!(~T[23:59:59], "Etc/UTC"))

    {time_min, time_max}
  end

  defp parse_boundary(nil, _edge), do: nil
  defp parse_boundary(%DateTime{} = value, _edge), do: value

  defp parse_boundary(%Date{} = value, :start), do: DateTime.new!(value, ~T[00:00:00], "Etc/UTC")
  defp parse_boundary(%Date{} = value, :end), do: DateTime.new!(value, ~T[23:59:59], "Etc/UTC")

  defp parse_boundary(value, edge) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, date_time, _offset} = DateTime.from_iso8601(value)
        date_time

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        parse_boundary(date, edge)

      true ->
        nil
    end
  end

  defp parse_boundary(_value, _edge), do: nil

  defp parse_integer(nil, default), do: default
  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
