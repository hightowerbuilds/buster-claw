defmodule BusterClaw.Scheduler.Cron do
  @moduledoc """
  Minimal five-field cron parser for local scheduler jobs.

  Supports numeric cron fields, `*`, comma lists, ranges, step values, and the
  common aliases used by the existing UI/tests. Evaluation is UTC and returns the
  next minute strictly after the supplied datetime.
  """

  @aliases %{
    "@annually" => "0 0 1 1 *",
    "@daily" => "0 0 * * *",
    "@hourly" => "0 * * * *",
    "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0",
    "@yearly" => "0 0 1 1 *"
  }

  @field_ranges [
    minute: 0..59,
    hour: 0..23,
    day: 1..31,
    month: 1..12,
    weekday: 0..7
  ]

  @max_minutes 366 * 24 * 60

  def valid?(expression), do: match?({:ok, _schedule}, parse(expression))

  def next_run(expression, from \\ DateTime.utc_now()) do
    with {:ok, schedule} <- parse(expression),
         {:ok, from} <- normalize_datetime(from) do
      next_minute(from)
      |> Stream.iterate(&DateTime.add(&1, 60, :second))
      |> Enum.take(@max_minutes)
      |> Enum.find(&matches?(schedule, &1))
      |> case do
        nil -> {:error, :no_matching_time}
        datetime -> {:ok, datetime}
      end
    end
  end

  def parse(expression) when is_binary(expression) do
    expression
    |> String.trim()
    |> expand_alias()
    |> String.split(~r/\s+/, trim: true)
    |> parse_fields()
  end

  def parse(_expression), do: {:error, :invalid_cron}

  defp expand_alias(expression), do: Map.get(@aliases, expression, expression)

  defp parse_fields(fields) when length(fields) == 5 do
    fields
    |> Enum.zip(@field_ranges)
    |> Enum.reduce_while({:ok, []}, fn {field, {name, range}}, {:ok, parsed} ->
      case parse_field(field, range, name) do
        {:ok, values, wildcard?} -> {:cont, {:ok, [{name, values, wildcard?} | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} ->
        {:ok, Map.new(parsed, fn {name, values, wildcard?} -> {name, {values, wildcard?}} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_fields(_fields), do: {:error, :invalid_cron}

  defp parse_field("*", range, _name), do: {:ok, MapSet.new(range), true}

  defp parse_field(field, range, name) do
    field
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, values} ->
      case parse_part(part, range, name) do
        {:ok, part_values} -> {:cont, {:ok, MapSet.union(values, part_values)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} ->
        if MapSet.size(values) > 0, do: {:ok, values, false}, else: {:error, :invalid_cron}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_part(part, range, name) do
    case String.split(part, "/", parts: 2) do
      [base] -> parse_range(base, range, name, 1)
      [base, step] -> parse_step(step, base, range, name)
    end
  end

  defp parse_step(step, base, range, name) do
    with {:ok, step} <- parse_integer(step),
         true <- step > 0 || {:error, :invalid_cron} do
      parse_range(base, range, name, step)
    end
  end

  defp parse_range("*", range, name, step), do: range_to_set(range, step, name)

  defp parse_range(base, range, name, step) do
    case String.split(base, "-", parts: 2) do
      [value] ->
        with {:ok, value} <- parse_integer(value),
             true <- value in range || {:error, :invalid_cron} do
          {:ok, MapSet.new([normalize_weekday(value, name)])}
        end

      [left, right] ->
        with {:ok, left} <- parse_integer(left),
             {:ok, right} <- parse_integer(right),
             true <- left <= right || {:error, :invalid_cron},
             true <- (left in range && right in range) || {:error, :invalid_cron} do
          left..right
          |> Enum.map(&normalize_weekday(&1, name))
          |> Enum.take_every(step)
          |> MapSet.new()
          |> then(&{:ok, &1})
        end
    end
  end

  defp range_to_set(range, step, name) do
    range
    |> Enum.map(&normalize_weekday(&1, name))
    |> Enum.take_every(step)
    |> MapSet.new()
    |> then(&{:ok, &1})
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_cron}
    end
  end

  defp normalize_weekday(7, :weekday), do: 0
  defp normalize_weekday(value, _name), do: value

  defp normalize_datetime(%DateTime{} = datetime) do
    {:ok, datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
  rescue
    _error -> {:error, :invalid_datetime}
  end

  defp normalize_datetime(_datetime), do: {:error, :invalid_datetime}

  defp next_minute(datetime) do
    datetime
    |> DateTime.add(60 - datetime.second, :second)
    |> DateTime.truncate(:second)
  end

  defp matches?(schedule, datetime) do
    date = DateTime.to_date(datetime)
    weekday = date |> Date.day_of_week() |> rem(7)

    value_matches?(schedule, :minute, datetime.minute) &&
      value_matches?(schedule, :hour, datetime.hour) &&
      value_matches?(schedule, :month, datetime.month) &&
      day_matches?(schedule, datetime.day, weekday)
  end

  defp value_matches?(schedule, key, value) do
    {values, _wildcard?} = Map.fetch!(schedule, key)
    MapSet.member?(values, value)
  end

  defp day_matches?(schedule, day, weekday) do
    {days, days_wildcard?} = Map.fetch!(schedule, :day)
    {weekdays, weekdays_wildcard?} = Map.fetch!(schedule, :weekday)

    day_matches? = MapSet.member?(days, day)
    weekday_matches? = MapSet.member?(weekdays, weekday)

    cond do
      days_wildcard? && weekdays_wildcard? -> true
      days_wildcard? -> weekday_matches?
      weekdays_wildcard? -> day_matches?
      true -> day_matches? || weekday_matches?
    end
  end
end
