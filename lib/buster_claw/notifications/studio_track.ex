defmodule BusterClaw.Notifications.StudioTrack do
  @moduledoc """
  A multi-lane arrangement — several stacked lanes, each holding clips placed at
  millisecond offsets, summed into one sound (SOUND_STUDIO_ROADMAP Phase 6).

  Where `SoundStudio` edits *one* file, this arranges *many*. A lane is a
  horizontal row; a clip is a reference to something in the Studio's catalog
  plus a start time. Lanes sum, so a bed on one lane and hits on another are
  heard together — that is the whole reason lanes exist rather than one long
  row.

  ## A clip stores a reference, not audio

  `source` is a catalog id (`"sound:alarm.wav"`, `"import:cut.wav"`), never a
  path and never bytes. An arrangement is therefore small, diffable, and
  survives its sources being re-edited — and a source that has *vanished* is a
  clip that reports itself missing rather than a track that will not open.
  `duration_ms` is cached alongside for layout, but a render re-reads the real
  file: the cache decides how wide a block draws, never what you hear.

  ## Persistence

  One JSON file per track under `<workspace>/studio/tracks/`, because that is
  where everything else in the Studio lives and because a track you can read,
  copy, and diff in Finder beats a row in a database nobody can see. The audio
  extension filter in `SoundStudio.list/0` means these never show up as
  importable clips.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Music

  @subdir Path.join("studio", "tracks")
  @ext ".track.json"

  # A fresh track opens with one lane, because zero lanes is a surface with
  # nothing to drop onto and "add a lane" as the only available move.
  @default_lanes 1
  @max_lanes 8

  defstruct name: nil, lanes: []

  @type clip :: %{
          id: binary(),
          source: binary(),
          start_ms: number(),
          duration_ms: number()
        }
  @type lane :: %{id: binary(), label: binary(), clips: [clip()]}
  @type t :: %__MODULE__{name: binary() | nil, lanes: [lane()]}

  # ---------------------------------------------------------------------------
  # Shape
  # ---------------------------------------------------------------------------

  @doc "A new track with one empty lane."
  def new(name) when is_binary(name) do
    %__MODULE__{name: name, lanes: Enum.map(1..@default_lanes, &lane(&1 - 1))}
  end

  @doc "The most lanes a track may hold."
  def max_lanes, do: @max_lanes

  defp lane(index) do
    %{id: new_id(), label: <<?A + rem(index, 26)>>, clips: []}
  end

  # Random rather than a counter: ids are persisted, and a counter restarting at
  # 1 on the next boot would collide with ids already in the file.
  defp new_id, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "Append a lane, up to `max_lanes/0`."
  def add_lane(%__MODULE__{lanes: lanes} = track) when length(lanes) < @max_lanes do
    %{track | lanes: lanes ++ [lane(length(lanes))]}
  end

  def add_lane(%__MODULE__{} = track), do: track

  @doc """
  Remove a lane and everything on it. The last lane is never removed — a track
  with no lanes cannot be added to.
  """
  def remove_lane(%__MODULE__{lanes: lanes} = track, _lane_id) when length(lanes) <= 1, do: track

  def remove_lane(%__MODULE__{} = track, lane_id) do
    %{track | lanes: Enum.reject(track.lanes, &(&1.id == lane_id))}
  end

  # ---------------------------------------------------------------------------
  # Clips
  # ---------------------------------------------------------------------------

  @doc """
  Place a clip on a lane. Negative offsets clamp to zero — the ruler starts at
  the beginning and there is no audio before it.
  """
  def add_clip(%__MODULE__{} = track, lane_id, source, start_ms, duration_ms)
      when is_binary(source) and is_number(start_ms) and is_number(duration_ms) do
    clip = %{
      id: new_id(),
      source: source,
      start_ms: max(0.0, start_ms * 1.0),
      duration_ms: max(0.0, duration_ms * 1.0)
    }

    update_lane(track, lane_id, fn lane -> %{lane | clips: lane.clips ++ [clip]} end)
  end

  @doc """
  Move a clip — along its lane, to another lane, or both.

  Removing then re-adding rather than mutating in place, because a move that
  crosses lanes is a removal and an insertion, and doing it as one operation is
  how a clip ends up existing on two lanes at once.
  """
  def move_clip(%__MODULE__{} = track, clip_id, to_lane_id, start_ms) when is_number(start_ms) do
    case pop_clip(track, clip_id) do
      {nil, _track} ->
        track

      {clip, stripped} ->
        moved = %{clip | start_ms: max(0.0, start_ms * 1.0)}

        if Enum.any?(stripped.lanes, &(&1.id == to_lane_id)) do
          update_lane(stripped, to_lane_id, fn lane -> %{lane | clips: lane.clips ++ [moved]} end)
        else
          # An unknown target lane puts the clip back where it was rather than
          # dropping it on the floor.
          track
        end
    end
  end

  @doc "Remove a clip from wherever it sits."
  def remove_clip(%__MODULE__{} = track, clip_id) do
    {_clip, stripped} = pop_clip(track, clip_id)
    stripped
  end

  @doc "Every clip in the track, paired with the lane holding it."
  def clips(%__MODULE__{lanes: lanes}) do
    Enum.flat_map(lanes, fn lane -> Enum.map(lane.clips, &{lane, &1}) end)
  end

  @doc "Where the arrangement ends, in ms — the furthest clip's far edge."
  def duration_ms(%__MODULE__{} = track) do
    track
    |> clips()
    |> Enum.map(fn {_lane, clip} -> clip.start_ms + clip.duration_ms end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp pop_clip(%__MODULE__{} = track, clip_id) do
    found = track |> clips() |> Enum.find_value(fn {_l, c} -> if c.id == clip_id, do: c end)

    stripped = %{
      track
      | lanes:
          Enum.map(
            track.lanes,
            &%{&1 | clips: Enum.reject(&1.clips, fn c -> c.id == clip_id end)}
          )
    }

    {found, stripped}
  end

  defp update_lane(%__MODULE__{} = track, lane_id, fun) do
    %{track | lanes: Enum.map(track.lanes, fn l -> if l.id == lane_id, do: fun.(l), else: l end)}
  end

  # ---------------------------------------------------------------------------
  # Layout — computed here, not in JS
  # ---------------------------------------------------------------------------
  #
  # The arranger's markup is server-rendered, so the ruler length and every clip
  # position are decided here and travel as HTML. The drag hook gets only the
  # ruler length, as a data attribute. Splitting it the other way would mean the
  # same formula in Elixir and JavaScript, free to drift.

  # The ruler always shows more than the arrangement uses, so there is somewhere
  # to drag a clip TO — a track that exactly fits its content has no room to grow.
  @headroom 1.25
  @min_view_ms 10_000

  @doc "How long a ruler to draw, rounded up to a whole second for clean ticks."
  def view_ms(%__MODULE__{} = track) do
    wanted = max(duration_ms(track) * @headroom, @min_view_ms)
    ceil(wanted / 1000) * 1000
  end

  @doc "A position along the ruler, as a percentage. Clamped to the container."
  def position_pct(ms, view) when is_number(ms) and is_number(view) and view > 0 do
    (ms / view * 100) |> max(0.0) |> min(100.0)
  end

  def position_pct(_ms, _view), do: 0.0

  @doc """
  A clip's drawn width. Floored at 1.5%, because a 12 ms hit on a 30 s ruler is
  0.04% wide — nothing a pointer can aim at, and clips must stay grabbable.
  """
  def width_pct(duration_ms, view) when is_number(duration_ms) and is_number(view) and view > 0 do
    (duration_ms / view * 100) |> max(1.5) |> min(100.0)
  end

  def width_pct(_duration, _view), do: 1.5

  @doc "Ruler ticks, thinning out as the view grows so labels stay readable."
  def ticks(view) when is_number(view) and view > 0 do
    step =
      cond do
        view <= 15_000 -> 1_000
        view <= 60_000 -> 5_000
        true -> 10_000
      end

    0..trunc(view)//step
    |> Enum.map(&%{ms: &1, pct: position_pct(&1, view), label: "#{div(&1, 1000)}s"})
  end

  def ticks(_view), do: []

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  @doc "Absolute path to `<workspace>/studio/tracks/`."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Sorted names of every saved track."
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, @ext))
        |> Enum.map(&String.replace_suffix(&1, @ext, ""))
        |> Enum.sort_by(&String.downcase/1)

      _ ->
        []
    end
  end

  @doc "Whether a track by this name exists."
  def exists?(name) when is_binary(name), do: name in list()

  @doc """
  Create and save a new track under a safe, collision-free name. Returns the
  name actually used, which may carry a `-2` suffix.
  """
  def create(requested) when is_binary(requested) do
    case safe_track_name(requested) do
      {:error, reason} ->
        {:error, reason}

      {:ok, base} ->
        name = available_name(base)

        case save(new(name)) do
          :ok -> {:ok, name}
          error -> error
        end
    end
  end

  @doc "Read a track by name."
  def load(name) when is_binary(name) do
    with true <- exists?(name),
         {:ok, body} <- File.read(path_for(name)),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, from_map(name, decoded)}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Write a track to disk."
  def save(%__MODULE__{name: name} = track) when is_binary(name) do
    File.mkdir_p(dir())

    case File.write(path_for(name), Jason.encode!(to_map(track), pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete a saved track. The clips it referenced are untouched."
  def delete(name) when is_binary(name) do
    if exists?(name), do: File.rm(path_for(name)), else: {:error, :not_found}
  end

  defp path_for(name), do: Path.join(dir(), name <> @ext)

  # A track name must carry at least one letter or digit. The check is on the
  # REQUEST, not on the sanitized result, because `Music.safe_name/1`
  # substitutes "track" for anything that reduces to nothing — so a check on its
  # output could never fire, and `"   "` would quietly become a track called
  # "track". Reusing that sanitizer is still right for everything after: it is
  # the one that already knows how to reduce `../../etc/evil` to a basename.
  defp safe_track_name(requested) do
    trimmed = String.trim(requested)

    if String.match?(trimmed, ~r/[\p{L}\p{N}]/u) do
      {:ok, trimmed |> Music.safe_name() |> String.replace_suffix(@ext, "") |> String.trim()}
    else
      {:error, :invalid_name}
    end
  end

  defp available_name(base), do: if(exists?(base), do: next_free(base, 2), else: base)

  defp next_free(base, n) do
    candidate = "#{base}-#{n}"
    if exists?(candidate), do: next_free(base, n + 1), else: candidate
  end

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  defp to_map(%__MODULE__{} = track) do
    %{
      "version" => 1,
      "name" => track.name,
      "lanes" =>
        Enum.map(track.lanes, fn lane ->
          %{
            "id" => lane.id,
            "label" => lane.label,
            "clips" =>
              Enum.map(lane.clips, fn clip ->
                %{
                  "id" => clip.id,
                  "source" => clip.source,
                  "start_ms" => clip.start_ms,
                  "duration_ms" => clip.duration_ms
                }
              end)
          }
        end)
    }
  end

  # Tolerant by design: this file is in the operator's workspace and they are
  # invited to edit it. A malformed lane is dropped, not a parse error that
  # makes the whole track unopenable.
  defp from_map(name, %{"lanes" => lanes}) when is_list(lanes) do
    parsed = lanes |> Enum.map(&parse_lane/1) |> Enum.reject(&is_nil/1)
    %__MODULE__{name: name, lanes: if(parsed == [], do: [lane(0)], else: parsed)}
  end

  defp from_map(name, _other), do: new(name)

  defp parse_lane(%{"id" => id, "clips" => clips} = lane) when is_binary(id) and is_list(clips) do
    %{
      id: id,
      label: Map.get(lane, "label", "?"),
      clips: clips |> Enum.map(&parse_clip/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp parse_lane(_lane), do: nil

  defp parse_clip(%{"id" => id, "source" => source, "start_ms" => start} = clip)
       when is_binary(id) and is_binary(source) and is_number(start) do
    %{
      id: id,
      source: source,
      start_ms: max(0.0, start * 1.0),
      duration_ms: max(0.0, Map.get(clip, "duration_ms", 0) * 1.0)
    }
  end

  defp parse_clip(_clip), do: nil
end
