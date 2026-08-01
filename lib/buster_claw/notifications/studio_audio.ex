defmodule BusterClaw.Notifications.StudioAudio do
  @moduledoc """
  An **audio** — the Studio's arrangement: several stacked tracks, each holding
  clips placed at millisecond offsets, summed into one sound
  (SOUND_STUDIO_ROADMAP Phase 6).

  Where `SoundStudio` edits *one* file, this arranges *many*. A track is a
  horizontal row; a clip is a reference to something in the Studio's catalog
  plus a start time. Tracks sum, so a bed on one track and hits on another are
  heard together — that is the whole reason tracks exist rather than one long
  row.

  ## Vocabulary, because it swapped once (2026-08-01)

  The UI originally called the arrangement a *track* and the rows *lanes*.
  Operators expect DAW terms — you add **tracks** to an **audio** — so the
  code now says what the UI says. The disk format below predates the swap and
  deliberately did not move with it.

  ## A clip stores a reference, not audio

  `source` is a catalog id (`"sound:alarm.wav"`, `"import:cut.wav"`), never a
  path and never bytes. An arrangement is therefore small, diffable, and
  survives its sources being re-edited — and a source that has *vanished* is a
  clip that reports itself missing rather than an audio that will not open.
  `duration_ms` is cached alongside for layout, but a render re-reads the real
  file: the cache decides how wide a block draws, never what you hear.

  ## Persistence — the v1 format is stable, and older-named on purpose

  One JSON file per audio under `<workspace>/sounds/studio/tracks/`, extension
  `.track.json`, rows under the key `"lanes"`. Those names are the v1
  serialization, written before the vocabulary swap, and they stay: the files
  live in the operator's workspace, are invited to be hand-edited, and may
  already exist. Renaming keys or extensions would orphan every saved
  arrangement to fix a label nobody sees in the app. `to_map/1` and
  `from_map/2` are the entire translation layer.

  The audio extension filter in `SoundStudio.list/0` means these never show up
  as importable clips.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Music

  # v1 disk layout — see the moduledoc before renaming either of these.
  @subdir Path.join(["sounds", "studio", "tracks"])
  @ext ".track.json"

  # A fresh audio opens with one track, because zero tracks is a surface with
  # nothing to drop onto and "add a track" as the only available move.
  @default_tracks 1
  @max_tracks 8

  defstruct name: nil, tracks: []

  @type clip :: %{
          id: binary(),
          source: binary(),
          start_ms: number(),
          duration_ms: number()
        }
  @type track :: %{
          id: binary(),
          label: binary(),
          muted: boolean(),
          soloed: boolean(),
          clips: [clip()]
        }
  @type t :: %__MODULE__{name: binary() | nil, tracks: [track()]}

  # ---------------------------------------------------------------------------
  # Shape
  # ---------------------------------------------------------------------------

  @doc "A new audio with one empty track."
  def new(name) when is_binary(name) do
    %__MODULE__{name: name, tracks: Enum.map(1..@default_tracks, &track(&1 - 1))}
  end

  @doc "The most tracks an audio may hold."
  def max_tracks, do: @max_tracks

  defp track(index) do
    %{id: new_id(), label: <<?A + rem(index, 26)>>, muted: false, soloed: false, clips: []}
  end

  # Random rather than a counter: ids are persisted, and a counter restarting at
  # 1 on the next boot would collide with ids already in the file.
  defp new_id, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "Append a track, up to `max_tracks/0`."
  def add_track(%__MODULE__{tracks: tracks} = audio) when length(tracks) < @max_tracks do
    %{audio | tracks: tracks ++ [track(length(tracks))]}
  end

  def add_track(%__MODULE__{} = audio), do: audio

  @doc """
  Remove a track and everything on it. The last track is never removed — an
  audio with no tracks cannot be added to.
  """
  def remove_track(%__MODULE__{tracks: tracks} = audio, _track_id) when length(tracks) <= 1,
    do: audio

  def remove_track(%__MODULE__{} = audio, track_id) do
    %{audio | tracks: Enum.reject(audio.tracks, &(&1.id == track_id))}
  end

  @doc "Flip a track's mute. Muting is per-track state, not a clip edit."
  def toggle_mute(%__MODULE__{} = audio, track_id) do
    update_track(audio, track_id, fn track -> %{track | muted: not track.muted} end)
  end

  @doc "Flip a track's solo."
  def toggle_solo(%__MODULE__{} = audio, track_id) do
    update_track(audio, track_id, fn track -> %{track | soloed: not track.soloed} end)
  end

  @doc """
  Whether a track sounds in the mix. The DAW contract: if ANY track is
  soloed, only soloed tracks sound; otherwise everything not muted sounds.
  Solo beats mute on the same track: engaging solo is the stronger, more
  recent statement of intent, and it is how Pro Tools and Logic both resolve
  the conflict, so it is what a DAW hand's fingers already expect.
  """
  def audible?(%__MODULE__{tracks: tracks}, %{} = track) do
    if Enum.any?(tracks, & &1.soloed), do: track.soloed, else: not track.muted
  end

  @doc "Every clip on every AUDIBLE track — what a render actually mixes."
  def audible_clips(%__MODULE__{} = audio) do
    audio
    |> clips()
    |> Enum.filter(fn {track, _clip} -> audible?(audio, track) end)
  end

  # ---------------------------------------------------------------------------
  # Clips
  # ---------------------------------------------------------------------------

  @doc """
  Place a clip on a track. Negative offsets clamp to zero — the ruler starts at
  the beginning and there is no audio before it.
  """
  def add_clip(%__MODULE__{} = audio, track_id, source, start_ms, duration_ms)
      when is_binary(source) and is_number(start_ms) and is_number(duration_ms) do
    clip = %{
      id: new_id(),
      source: source,
      start_ms: max(0.0, start_ms * 1.0),
      duration_ms: max(0.0, duration_ms * 1.0)
    }

    update_track(audio, track_id, fn track -> %{track | clips: track.clips ++ [clip]} end)
  end

  @doc """
  Move a clip — along its track, to another track, or both.

  Removing then re-adding rather than mutating in place, because a move that
  crosses tracks is a removal and an insertion, and doing it as one operation is
  how a clip ends up existing on two tracks at once.
  """
  def move_clip(%__MODULE__{} = audio, clip_id, to_track_id, start_ms) when is_number(start_ms) do
    case pop_clip(audio, clip_id) do
      {nil, _audio} ->
        audio

      {clip, stripped} ->
        moved = %{clip | start_ms: max(0.0, start_ms * 1.0)}

        if Enum.any?(stripped.tracks, &(&1.id == to_track_id)) do
          update_track(stripped, to_track_id, fn track ->
            %{track | clips: track.clips ++ [moved]}
          end)
        else
          # An unknown target track puts the clip back where it was rather than
          # dropping it on the floor.
          audio
        end
    end
  end

  @doc "Remove a clip from wherever it sits."
  def remove_clip(%__MODULE__{} = audio, clip_id) do
    {_clip, stripped} = pop_clip(audio, clip_id)
    stripped
  end

  @doc "Every clip in the audio, paired with the track holding it."
  def clips(%__MODULE__{tracks: tracks}) do
    Enum.flat_map(tracks, fn track -> Enum.map(track.clips, &{track, &1}) end)
  end

  @doc "Where the arrangement ends, in ms — the furthest clip's far edge."
  def duration_ms(%__MODULE__{} = audio) do
    audio
    |> clips()
    |> Enum.map(fn {_track, clip} -> clip.start_ms + clip.duration_ms end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp pop_clip(%__MODULE__{} = audio, clip_id) do
    found = audio |> clips() |> Enum.find_value(fn {_t, c} -> if c.id == clip_id, do: c end)

    stripped = %{
      audio
      | tracks:
          Enum.map(
            audio.tracks,
            &%{&1 | clips: Enum.reject(&1.clips, fn c -> c.id == clip_id end)}
          )
    }

    {found, stripped}
  end

  defp update_track(%__MODULE__{} = audio, track_id, fun) do
    %{
      audio
      | tracks: Enum.map(audio.tracks, fn t -> if t.id == track_id, do: fun.(t), else: t end)
    }
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
  # to drag a clip TO — an audio that exactly fits its content has no room to grow.
  @headroom 1.25
  @min_view_ms 10_000

  @doc "How long a ruler to draw, rounded up to a whole second for clean ticks."
  def view_ms(%__MODULE__{} = audio) do
    wanted = max(duration_ms(audio) * @headroom, @min_view_ms)
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

  @doc "Absolute path to `<workspace>/sounds/studio/tracks/` (v1 layout — moduledoc)."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Sorted names of every saved audio."
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

  @doc "Whether an audio by this name exists."
  def exists?(name) when is_binary(name), do: name in list()

  @doc """
  Create and save a new audio under a safe, collision-free name. Returns the
  name actually used, which may carry a `-2` suffix.
  """
  def create(requested) when is_binary(requested) do
    case safe_audio_name(requested) do
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

  @doc "Read an audio by name."
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

  @doc "Write an audio to disk."
  def save(%__MODULE__{name: name} = audio) when is_binary(name) do
    File.mkdir_p(dir())

    case File.write(path_for(name), Jason.encode!(to_map(audio), pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete a saved audio. The clips it referenced are untouched."
  def delete(name) when is_binary(name) do
    if exists?(name), do: File.rm(path_for(name)), else: {:error, :not_found}
  end

  defp path_for(name), do: Path.join(dir(), name <> @ext)

  # An audio name must carry at least one letter or digit. The check is on the
  # REQUEST, not on the sanitized result, because `Music.safe_name/1`
  # substitutes "track" for anything that reduces to nothing — so a check on its
  # output could never fire, and `"   "` would quietly become an audio called
  # "track". Reusing that sanitizer is still right for everything after: it is
  # the one that already knows how to reduce `../../etc/evil` to a basename.
  defp safe_audio_name(requested) do
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
  # JSON — the v1 format speaks the OLD vocabulary ("lanes"), on purpose.
  # These two functions are the entire translation layer; see the moduledoc.
  # ---------------------------------------------------------------------------

  defp to_map(%__MODULE__{} = audio) do
    %{
      "version" => 1,
      "name" => audio.name,
      "lanes" =>
        Enum.map(audio.tracks, fn track ->
          %{
            "id" => track.id,
            "label" => track.label,
            "muted" => track.muted,
            "soloed" => track.soloed,
            "clips" =>
              Enum.map(track.clips, fn clip ->
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
  # invited to edit it. A malformed track is dropped, not a parse error that
  # makes the whole audio unopenable.
  defp from_map(name, %{"lanes" => lanes}) when is_list(lanes) do
    parsed = lanes |> Enum.map(&parse_track/1) |> Enum.reject(&is_nil/1)
    %__MODULE__{name: name, tracks: if(parsed == [], do: [track(0)], else: parsed)}
  end

  defp from_map(name, _other), do: new(name)

  defp parse_track(%{"id" => id, "clips" => clips} = track)
       when is_binary(id) and is_list(clips) do
    %{
      id: id,
      label: Map.get(track, "label", "?"),
      # `== true`, not truthiness: this file is hand-editable, and a helpful
      # human writing "muted": "yes" should get an ignored key, not a track
      # that cannot be unmuted from the UI's boolean flip.
      muted: Map.get(track, "muted") == true,
      soloed: Map.get(track, "soloed") == true,
      clips: clips |> Enum.map(&parse_clip/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp parse_track(_track), do: nil

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
