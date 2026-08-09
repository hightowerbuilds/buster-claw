defmodule BusterClaw.Notifications.Schedule do
  @moduledoc """
  When a Notify widget submission should fire — the wall-clock arithmetic behind
  the timer / alarm / reminder form.

  Extracted from `StatusLive` (CODE_QUALITY_REFACTOR Phase 3B, 08-03). It was
  pure the whole time and simply lived in a LiveView, which meant the only way
  to test "what does 11:30pm mean when it is 11:45pm" was to drive a mount, an
  event and a form. Nothing here touches a socket, so the DST and
  next-occurrence cases can be asserted directly.

  The clock is injectable for exactly that reason: `fire_at/3` takes `now` so a
  test can stand at a chosen moment instead of racing the machine's.
  """

  @type params :: %{optional(String.t()) => term()}
  @type result :: {:ok, DateTime.t()} | {:error, atom(), String.t()}

  @doc """
  The moment a submission should fire, per kind.

  A timer counts down from `now`; alarms **and** reminders arm the next local
  wall-clock occurrence of the picked time. (The `notify_create` command's
  reminder fires immediately — that is the agent announcing something now; a
  human setting a reminder is scheduling its announcement.)

  Errors carry the form field to attach them to, so the caller can render them
  without re-deriving which input was wrong.
  """
  @spec fire_at(String.t(), params(), DateTime.t()) :: result()
  def fire_at(kind, params, now \\ utc_now())

  def fire_at("timer", params, now) do
    case params |> Map.get("minutes", "") |> parse_minutes() do
      :error -> {:error, :minutes, "minutes must be a positive number"}
      minutes -> {:ok, DateTime.add(now, minutes * 60, :second)}
    end
  end

  def fire_at(kind, params, _now) when kind in ["alarm", "reminder"] do
    case parse_wall_time(Map.get(params, "at", "")) do
      {:ok, time} -> {:ok, next_local_occurrence(time)}
      :error -> {:error, :at, "pick a time"}
    end
  end

  def fire_at(_kind, _params, _now), do: {:error, :label, "unknown kind"}

  @doc """
  An alarm's label is optional — a bedside clock does not need naming — so a
  blank one becomes "Alarm" (the schema and the list/modal both require a
  label). Timers and reminders keep theirs: the label IS the message.
  """
  @spec default_label(String.t(), String.t()) :: String.t()
  def default_label("", "alarm"), do: "Alarm"
  def default_label(label, _kind), do: label

  @doc """
  The next moment the Mac's local clock reads `time`, as UTC: today if still
  ahead, else tomorrow.

  The offset comes from comparing the OS local clock to UTC (there is no tz
  database in the app), rounded to 15-minute granularity — real offsets are — so
  the seconds between the two reads cannot skew it. An alarm set across a DST
  flip lands an hour off; acceptable for a bedside clock, and written down here
  rather than discovered later.
  """
  @spec next_local_occurrence(Time.t()) :: DateTime.t()
  def next_local_occurrence(%Time{} = time) do
    local_now = NaiveDateTime.from_erl!(:calendar.local_time())
    candidate = NaiveDateTime.new!(NaiveDateTime.to_date(local_now), time)

    candidate =
      if NaiveDateTime.compare(candidate, local_now) == :gt,
        do: candidate,
        else: NaiveDateTime.add(candidate, 86_400, :second)

    utc_now = NaiveDateTime.from_erl!(:calendar.universal_time())
    offset = round(NaiveDateTime.diff(local_now, utc_now) / 900) * 900

    candidate
    |> NaiveDateTime.add(-offset, :second)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  # Positive whole minutes, or `:error`. A trailing unit is tolerated.
  @spec parse_minutes(term()) :: pos_integer() | :error
  defp parse_minutes(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {minutes, _rest} when minutes > 0 -> minutes
      _ -> :error
    end
  end

  @doc ~S|`<input type="time">` submits `"HH:MM"`, sometimes `"HH:MM:SS"`.|
  @spec parse_wall_time(term()) :: {:ok, Time.t()} | :error
  def parse_wall_time(value) do
    value = String.trim(to_string(value))
    padded = if String.length(value) == 5, do: value <> ":00", else: value

    case Time.from_iso8601(padded) do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
