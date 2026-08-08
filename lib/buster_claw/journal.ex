defmodule BusterClaw.Journal do
  @moduledoc """
  The **Activity record**: the single place Buster Claw activity is logged. One
  rolling markdown document per calendar day under `<workspace>/journal/`,
  named `YYYY-MM-DD.md`, surfaced as the homepage **Activity** tab.

  There is deliberately no second activity log. `.buster-claw/dispatch/<date>/Dispatch.*` is a
  machine projection of queue events, `analysis/` holds per-request findings,
  and `activity_report` is computed from dispatch rows — none of them is where
  "what happened today" is written. This is.

  The agent appends through `journal_append`; the Activity UI is read-only.
  Existing operator entries are preserved and the lower-level API still accepts
  `:operator` for compatibility. Every entry lands chronologically under a
  `###### HH:MM` timestamp heading, with operator entries carrying an
  ` — OPERATOR` suffix. A day's file is created on its first entry. Like the rest
  of the workspace, this is plain Markdown you own: no database, `grep` works.

  ## Safety

  Unlike `notes/` (where the filename was a free-text title), journal filenames
  are derived exclusively from `Date` values — `get/1` parses its argument as an
  ISO 8601 date before touching the filesystem, so no caller-controlled string
  ever becomes a path segment.
  """

  alias BusterClaw.Library.Artifact
  alias BusterClaw.LocalTime

  @extension ".md"
  @topic "journal"
  @max_entry 20_000

  @doc "Absolute path to the workspace journal directory."
  def dir, do: Artifact.workspace_path("journal")

  @doc "Create the journal directory if it doesn't exist (best-effort)."
  def ensure do
    File.mkdir_p(dir())
    :ok
  end

  @doc "Subscribe the calling process to journal updates (`{:journal_appended, iso_date}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Append one entry to today's Activity record. `source` is `:agent` or `:operator`;
  operator entries are marked in the timestamp heading. Creates the day's
  document (with a title line) on the first entry. Returns `{:ok, day}` with
  the updated day map, or `{:error, :blank}` for empty text.

  Options: `:now` (a `NaiveDateTime`) for deterministic timestamps in tests.
  """
  def append(text, source, opts \\ []) when source in [:agent, :operator] do
    now = Keyword.get(opts, :now) || NaiveDateTime.local_now()
    entry = text |> to_string() |> String.trim() |> String.slice(0, @max_entry)

    if entry == "" do
      {:error, :blank}
    else
      ensure()
      date = NaiveDateTime.to_date(now)
      path = path_for(date)
      File.write!(path, render_entry(entry, source, now, File.exists?(path), date), [:append])

      broadcast(date)
      {:ok, get(Date.to_iso8601(date))}
    end
  end

  @doc """
  List journal days as `%{date: Date.t(), name: String.t()}`, newest first.
  `name` is the ISO date string (also the display label and lookup key).
  """
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == @extension))
        |> Enum.flat_map(fn entry ->
          case Date.from_iso8601(Path.rootname(entry, @extension)) do
            {:ok, date} -> [%{date: date, name: Date.to_iso8601(date)}]
            _ -> []
          end
        end)
        |> Enum.sort_by(& &1.date, {:desc, Date})

      {:error, _} ->
        []
    end
  end

  @doc """
  Read one day's Activity record by ISO date string. Returns
  `%{date: Date.t(), name: String.t(), body: String.t()}` or `nil` when the
  day has no document (or the name isn't a date).
  """
  def get(name) when is_binary(name) do
    with {:ok, date} <- Date.from_iso8601(name),
         {:ok, body} <- File.read(path_for(date)) do
      %{date: date, name: Date.to_iso8601(date), body: body}
    else
      _ -> nil
    end
  end

  def get(_), do: nil

  @doc "Today's lookup key (local ISO date string)."
  def today_name, do: Date.to_iso8601(LocalTime.today())

  # --- internals ---

  defp path_for(%Date{} = date), do: Path.join(dir(), Date.to_iso8601(date) <> @extension)

  defp render_entry(entry, source, now, exists?, date) do
    header = if exists?, do: "", else: "# Minutes — #{Date.to_iso8601(date)}\n"
    header <> "\n###### #{stamp(now)}#{marker(source)}\n\n#{entry}\n"
  end

  defp stamp(%NaiveDateTime{hour: h, minute: m}) do
    "#{String.pad_leading("#{h}", 2, "0")}:#{String.pad_leading("#{m}", 2, "0")}"
  end

  defp marker(:operator), do: " — OPERATOR"
  defp marker(:agent), do: ""

  defp broadcast(date) do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      @topic,
      {:journal_appended, Date.to_iso8601(date)}
    )
  end
end
