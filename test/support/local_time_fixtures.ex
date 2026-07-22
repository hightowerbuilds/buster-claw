defmodule BusterClaw.LocalTimeFixtures do
  @moduledoc """
  Timezone-independent calendar fixtures.

  Google sync deliberately converts an RFC3339 instant to the runtime's local
  wall clock (`CalendarSync` via `parse_wall_datetime`). A fixture hard-coding
  `-07:00` therefore only round-trips its wall time on a Pacific machine —
  which is how three calendar tests passed locally for weeks and failed the
  moment CI's UTC runner actually reached `mix test`.

  `local_rfc3339/1` renders a wall time with the *runtime's own* UTC offset for
  that instant, so `~T[09:30:00]` in a fixture asserts back as `~T[09:30:00]`
  in every timezone.
  """

  @doc "The naive wall time as an RFC3339 string in the runtime's local offset."
  def local_rfc3339(%NaiveDateTime{} = naive) do
    local_erl = NaiveDateTime.to_erl(naive)

    case :calendar.local_time_to_universal_time_dst(local_erl) do
      [utc_erl | _] ->
        offset =
          :calendar.datetime_to_gregorian_seconds(local_erl) -
            :calendar.datetime_to_gregorian_seconds(utc_erl)

        NaiveDateTime.to_iso8601(naive) <> format_offset(offset)

      [] ->
        raise ArgumentError,
              "#{inspect(naive)} does not exist in this timezone (DST gap) — pick another fixture time"
    end
  end

  defp format_offset(0), do: "+00:00"

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(seconds)
    hours = total |> div(3600) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = total |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}#{hours}:#{minutes}"
  end
end
