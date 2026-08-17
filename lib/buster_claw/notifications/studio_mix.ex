defmodule BusterClaw.Notifications.StudioMix do
  @moduledoc """
  A **mix** — the Studio's arrangement: several stacked tracks, each holding
  clips placed at millisecond offsets, summed into one sound
  (SOUND_STUDIO_ROADMAP Phase 6).

  Where `SoundStudio` edits *one* file, this arranges *many*. A track is a
  horizontal row; a clip is a reference to something in the Studio's catalog
  plus a start time. Tracks sum, so a bed on one track and hits on another are
  heard together — that is the whole reason tracks exist rather than one long
  row.

  ## Vocabulary, which has now settled (2026-08-02)

  This has been renamed twice. The UI first called the arrangement a *track*
  and its rows *lanes*; on 08-01 that became an *audio* holding *tracks*; on
  08-02 the arrangement became a **mix**, because "audio" was doing two jobs at
  once — an imported `.wav` is audio too, so "add this audio to that audio"
  was a sentence the UI could not say clearly. A **mix** holds **tracks**, each
  holding **clips**. One word per thing.

  ## A clip stores a reference, not audio

  `source` is a catalog id (`"sound:alarm.wav"`, `"import:cut.wav"`), never a
  path and never bytes. A mix is therefore small, diffable, and survives its
  sources being re-edited — and a source that has *vanished* is a clip that
  reports itself missing rather than a mix that will not open. `duration_ms` is
  cached alongside for layout, but a render re-reads the real file: the cache
  decides how wide a block draws, never what you hear.

  ## Persistence — v2, and it reads v1

  One JSON file per mix under `<workspace>/sounds/studio/mixes/`, extension
  `.mix.json`, rows under `"tracks"`.

  The v1 format said `tracks/`, `.track.json` and `"lanes"` — the words of the
  *first* naming. It was deliberately left alone through the 08-01 rename on
  the grounds that these files are hand-editable and may already exist. A
  second rename changed that calculus: the cost of keeping v1 was no longer one
  stale word but **three vocabularies in one system** — disk saying `lanes`,
  code saying `tracks`, UI saying `mix` — which is how a hand-editable format
  stops being hand-editable. So v2 moves, and the promise is kept a different
  way: `migrate_v1/0` renames the directory and files on boot, `from_map/2`
  still accepts `"lanes"`, and no arrangement is orphaned. `to_map/1` and
  `from_map/2` remain the entire translation layer.

  The mix extension filter in `SoundStudio.list/0` means these never show up as
  importable clips.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Music
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.Studio.Effects

  # v2 disk layout. See the moduledoc: v1 (`tracks/`, `.track.json`, `"lanes"`)
  # is migrated on boot and still readable, so nothing is orphaned.
  @subdir Path.join(["sounds", "studio", "mixes"])
  @ext ".mix.json"

  @v1_subdir Path.join(["sounds", "studio", "tracks"])
  @v1_ext ".track.json"

  # A fresh mix opens with one track, because zero tracks is a surface with
  # nothing to drop onto and "add a track" as the only available move.
  @default_tracks 1
  @max_tracks 8

  defstruct name: nil, tracks: []

  @type clip :: %{
          id: binary(),
          source: binary(),
          start_ms: number(),
          offset_ms: number(),
          duration_ms: number(),
          effects: [BusterClaw.Notifications.Studio.Effects.effect()]
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

  @doc """
  Prepare the Studio: its folder, and the mix layout's v1→v2 fold.

  This used to be the other way round — `SoundStudio.ensure/0` called
  `migrate_v1/0`, on the reasoning that the folder is made there so the fold
  belongs there too. It reads well and it pointed the dependency **upwards**: the
  audio-format module, which the cut-up engine and the recorder both sit on, knew
  about arrangements.

  `check_cycles.sh` found it the moment `Studio.Effects` arrived and closed the
  loop (`SoundStudio → StudioMix → Effects → SoundStudio`). The fix is this
  function: the mix layer prepares itself and calls down to the format layer,
  which is the direction that was always true.
  """
  def ensure do
    SoundStudio.ensure()
    migrate_v1()
    :ok
  end

  @doc "A new mix with one empty track."
  def new(name) when is_binary(name) do
    %__MODULE__{name: name, tracks: Enum.map(1..@default_tracks, &track(&1 - 1))}
  end

  @doc "The most tracks a mix may hold."
  def max_tracks, do: @max_tracks

  defp track(index) do
    %{id: new_id(), label: <<?A + rem(index, 26)>>, muted: false, soloed: false, clips: []}
  end

  # Random rather than a counter: ids are persisted, and a counter restarting at
  # 1 on the next boot would collide with ids already in the file.
  defp new_id, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "Append a track, up to `max_tracks/0`."
  def add_track(%__MODULE__{tracks: tracks} = mix) when length(tracks) < @max_tracks do
    %{mix | tracks: tracks ++ [track(length(tracks))]}
  end

  def add_track(%__MODULE__{} = mix), do: mix

  @doc """
  Remove a track and everything on it. The last track is never removed — an
  mix with no tracks cannot be added to.
  """
  def remove_track(%__MODULE__{tracks: tracks} = mix, _track_id) when length(tracks) <= 1,
    do: mix

  def remove_track(%__MODULE__{} = mix, track_id) do
    %{mix | tracks: Enum.reject(mix.tracks, &(&1.id == track_id))}
  end

  @doc "Flip a track's mute. Muting is per-track state, not a clip edit."
  def toggle_mute(%__MODULE__{} = mix, track_id) do
    update_track(mix, track_id, fn track -> %{track | muted: not track.muted} end)
  end

  @doc "Flip a track's solo."
  def toggle_solo(%__MODULE__{} = mix, track_id) do
    update_track(mix, track_id, fn track -> %{track | soloed: not track.soloed} end)
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
  def audible_clips(%__MODULE__{} = mix) do
    mix
    |> clips()
    |> Enum.filter(fn {track, _clip} -> audible?(mix, track) end)
  end

  # ---------------------------------------------------------------------------
  # Clips
  # ---------------------------------------------------------------------------

  @doc """
  Place a clip on a track. Negative offsets clamp to zero — the ruler starts at
  the beginning and there is no audio before it.
  """
  def add_clip(%__MODULE__{} = mix, track_id, source, start_ms, duration_ms)
      when is_binary(source) and is_number(start_ms) and is_number(duration_ms) do
    clip = %{
      id: new_id(),
      source: source,
      start_ms: max(0.0, start_ms * 1.0),
      offset_ms: 0.0,
      duration_ms: max(0.0, duration_ms * 1.0),
      effects: []
    }

    update_track(mix, track_id, fn track -> %{track | clips: track.clips ++ [clip]} end)
  end

  @doc """
  Place a copy of a clip spec on a track, with a NEW id.

  The spec is `%{source, duration_ms, effects}` — whatever `duplicate_clip/2`
  found or the clipboard is holding. One function for both, because "make a new
  clip that sounds like this one" is one operation and having two of it is how
  the copy path came to drop effects while duplicate kept them.

  **Effects ride along.** A clip you have shaped is the clip you meant to copy;
  a duplicate that came back dry would be a worse-than-useless shortcut, since
  the loss is silent and only audible on render.
  """
  def place_copy(%__MODULE__{} = mix, spec, track_id, start_ms) when is_number(start_ms) do
    clip = %{
      id: new_id(),
      source: spec.source,
      start_ms: max(0.0, start_ms * 1.0),
      # A copy inherits the ORIGINAL's window. Duplicating a trimmed clip and
      # getting the whole source back would be the same class of silent loss as
      # the dry-paste bug fixed on 08-16.
      offset_ms: max(0.0, Map.get(spec, :offset_ms, 0) * 1.0),
      duration_ms: max(0.0, Map.get(spec, :duration_ms, 0) * 1.0),
      effects: Map.get(spec, :effects) || []
    }

    update_track(mix, track_id, fn track -> %{track | clips: track.clips ++ [clip]} end)
  end

  @doc """
  Duplicate a clip: the same audio, the same chain, on the same track,
  immediately after the original.

  **Immediately after, not at the end of the track**, which is where paste puts
  things. The two gestures mean different things: paste is "put this somewhere",
  duplicate is "again, right here" — the DAW convention, and the one that makes
  doubling a hit a single action rather than a drag afterwards.

  Silently does nothing for an unknown id, matching `move_clip/4` and
  `remove_clip/2`: a stale client should cost a no-op, never a crash.
  """
  def duplicate_clip(%__MODULE__{} = mix, clip_id) do
    case Enum.find(clips(mix), fn {_track, clip} -> clip.id == clip_id end) do
      nil ->
        mix

      {track, clip} ->
        place_copy(mix, clip, track.id, clip.start_ms + clip.duration_ms)
    end
  end

  @doc """
  Move a clip — along its track, to another track, or both.

  Removing then re-adding rather than mutating in place, because a move that
  crosses tracks is a removal and an insertion, and doing it as one operation is
  how a clip ends up existing on two tracks at once.
  """
  def move_clip(%__MODULE__{} = mix, clip_id, to_track_id, start_ms) when is_number(start_ms) do
    case pop_clip(mix, clip_id) do
      {nil, _mix} ->
        mix

      {clip, stripped} ->
        moved = %{clip | start_ms: max(0.0, start_ms * 1.0)}

        if Enum.any?(stripped.tracks, &(&1.id == to_track_id)) do
          update_track(stripped, to_track_id, fn track ->
            %{track | clips: track.clips ++ [moved]}
          end)
        else
          # An unknown target track puts the clip back where it was rather than
          # dropping it on the floor.
          mix
        end
    end
  end

  @doc """
  Add an effect to a clip's chain, at the end.

  Appending rather than inserting is the whole ordering model: the chain is the
  order the operator built it in, and `Studio.Effects` applies it in that order
  because reverb-then-reverse and reverse-then-reverb are different sounds.

  An unknown type is ignored — `Effects.build/1` is what decides what exists, so
  a stale client cannot put something unrenderable into a mix file.
  """
  def add_effect(%__MODULE__{} = mix, clip_id, type) do
    case Effects.build(type) do
      {:ok, effect} -> update_clip(mix, clip_id, &%{&1 | effects: chain(&1) ++ [effect]})
      :error -> mix
    end
  end

  @doc "Remove the effect at `position` (0-based) from a clip's chain."
  def remove_effect(%__MODULE__{} = mix, clip_id, position) when is_integer(position) do
    update_clip(mix, clip_id, fn clip ->
      %{clip | effects: List.delete_at(chain(clip), position)}
    end)
  end

  def remove_effect(%__MODULE__{} = mix, _clip_id, _position), do: mix

  @doc """
  Set one parameter of the effect at `position`, clamped to its declared range.

  The clamp lives in `Studio.Effects`, not here: this module owns the shape of an
  arrangement and knows nothing about what a reverb's `size` may be.
  """
  def put_effect_param(%__MODULE__{} = mix, clip_id, position, key, value)
      when is_integer(position) do
    update_clip(mix, clip_id, fn clip ->
      case Enum.at(chain(clip), position) do
        nil ->
          clip

        effect ->
          %{
            clip
            | effects:
                List.replace_at(chain(clip), position, Effects.put_param(effect, key, value))
          }
      end
    end)
  end

  def put_effect_param(%__MODULE__{} = mix, _clip_id, _position, _key, _value), do: mix

  @doc "Drop every effect from a clip — the way back to the raw source."
  def clear_effects(%__MODULE__{} = mix, clip_id),
    do: update_clip(mix, clip_id, &%{&1 | effects: []})

  @doc """
  A clip's effect chain, tolerant of a clip that predates the field.

  Every mix written before 08-16 has clips with no `effects` key at all, and they
  must keep opening. Reading through this rather than `clip.effects` is what makes
  that true everywhere at once.
  """
  def chain(clip), do: Map.get(clip, :effects) || []

  @doc """
  A clip's window into its source, as `{offset_ms, duration_ms}`.

  **The window is the clip's, not the file's.** Trimming a clip narrows what the
  mix uses; the source on disk is never touched, so the same file can appear
  twice in one mix trimmed two different ways, and re-adding it always brings
  the whole thing back.

  Tolerant of a clip written before `offset_ms` existed, exactly as `chain/1` is
  for `effects`: every mix from before 08-16 has no such key and must keep
  opening. `0` is also the correct answer for those clips — they start at the
  beginning of their source.
  """
  def window(clip), do: {Map.get(clip, :offset_ms) || 0.0, clip.duration_ms}

  @doc """
  Trim a clip to a window of its source.

  `offset_ms` is where the clip starts INSIDE the source; `duration_ms` is how
  much of it the mix uses. Neither can be negative — a clip reaching before the
  start of its own file is not a thing — and a zero-length window is refused
  rather than silently written, because a clip you cannot hear and cannot see is
  worse than a rejected edit.

  It does not move the clip on the timeline: `start_ms` is untouched. Trimming
  changes what plays, not when.
  """
  def trim_clip(%__MODULE__{} = mix, clip_id, offset_ms, duration_ms)
      when is_number(offset_ms) and is_number(duration_ms) do
    if duration_ms <= 0 do
      mix
    else
      update_clip(mix, clip_id, fn clip ->
        clip
        |> Map.put(:offset_ms, max(0.0, offset_ms * 1.0))
        |> Map.put(:duration_ms, max(0.0, duration_ms * 1.0))
      end)
    end
  end

  def trim_clip(%__MODULE__{} = mix, _clip_id, _offset_ms, _duration_ms), do: mix

  @doc "The clip with `id`, wherever it sits, or `nil`."
  def find_clip(%__MODULE__{} = mix, clip_id) do
    Enum.find_value(mix.tracks, fn track -> Enum.find(track.clips, &(&1.id == clip_id)) end)
  end

  # One path for "change this clip in place", so the four effect operations above
  # cannot each invent their own traversal.
  defp update_clip(%__MODULE__{} = mix, clip_id, fun) do
    tracks =
      Enum.map(mix.tracks, fn track ->
        %{
          track
          | clips: Enum.map(track.clips, fn c -> if c.id == clip_id, do: fun.(c), else: c end)
        }
      end)

    %{mix | tracks: tracks}
  end

  @doc "Remove a clip from wherever it sits."
  def remove_clip(%__MODULE__{} = mix, clip_id) do
    {_clip, stripped} = pop_clip(mix, clip_id)
    stripped
  end

  @doc """
  Where a track's audio ends — the largest `start_ms + duration_ms` on it, or
  `0.0` for an empty track. This is where an appended clip goes.

  Consolidated here 08-03: `StatusLive` and `SoundStudioComponent` each carried
  their own copy, in different shapes (one taking a track, one taking a mix and
  a track id) and neither aware of the other. Two implementations of "where does
  this track end" is one drifting apart later, on a number that decides where
  audio lands.
  """
  def track_end_ms(%{clips: clips}) do
    clips |> Enum.map(&(&1.start_ms + &1.duration_ms)) |> Enum.max(fn -> 0.0 end)
  end

  def track_end_ms(%__MODULE__{tracks: tracks}, track_id) do
    tracks
    |> Enum.find(%{clips: []}, &(&1.id == track_id))
    |> track_end_ms()
  end

  @doc """
  The track a paste should land on: the one already holding `clip_id`, else the
  first. Pasting near the clip you copied is what the operator means.
  """
  def paste_track(%__MODULE__{tracks: tracks} = mix, clip_id) do
    holder =
      mix
      |> clips()
      |> Enum.find_value(fn {track, clip} -> if clip.id == clip_id, do: track end)

    holder || hd(tracks)
  end

  @doc "Every clip in the mix, paired with the track holding it."
  def clips(%__MODULE__{tracks: tracks}) do
    Enum.flat_map(tracks, fn track -> Enum.map(track.clips, &{track, &1}) end)
  end

  @doc "Where the arrangement ends, in ms — the furthest clip's far edge."
  def duration_ms(%__MODULE__{} = mix) do
    mix
    |> clips()
    |> Enum.map(fn {_track, clip} -> clip.start_ms + clip.duration_ms end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp pop_clip(%__MODULE__{} = mix, clip_id) do
    found = mix |> clips() |> Enum.find_value(fn {_t, c} -> if c.id == clip_id, do: c end)

    stripped = %{
      mix
      | tracks:
          Enum.map(
            mix.tracks,
            &%{&1 | clips: Enum.reject(&1.clips, fn c -> c.id == clip_id end)}
          )
    }

    {found, stripped}
  end

  defp update_track(%__MODULE__{} = mix, track_id, fun) do
    %{
      mix
      | tracks: Enum.map(mix.tracks, fn t -> if t.id == track_id, do: fun.(t), else: t end)
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
  # to drag a clip TO — an mix that exactly fits its content has no room to grow.
  @headroom 1.25
  @min_view_ms 10_000

  @doc "How long a ruler to draw, rounded up to a whole second for clean ticks."
  def view_ms(%__MODULE__{} = mix) do
    wanted = max(duration_ms(mix) * @headroom, @min_view_ms)
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

  @doc "Absolute path to `<workspace>/sounds/studio/mixes/`."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc """
  Fold a v1 layout (`tracks/`, `.track.json`) into v2 (`mixes/`, `.mix.json`).

  Idempotent by shape: once the old directory is gone there is nothing to do.
  A name that already exists at the destination is **left alone and logged** —
  the same posture as every other migration in this app, because we do not get
  to pick which of a user's two files survives. The `"lanes"` key needs no
  migration at all: `from_map/2` still reads it, and the next save writes v2.
  """
  def migrate_v1 do
    old = Artifact.workspace_path(@v1_subdir)

    if File.dir?(old) do
      File.mkdir_p!(dir())
      kept = old |> File.ls!() |> Enum.reject(&move_v1_file(old, &1))

      case kept do
        [] ->
          File.rmdir(old)
          Logger.info("StudioMix: migrated studio/tracks/ to studio/mixes/")

        names ->
          Logger.warning(
            "StudioMix: kept studio/tracks/ — #{length(names)} item(s) already exist " <>
              "under studio/mixes/ and were not overwritten: #{Enum.join(names, ", ")}"
          )
      end
    end

    :ok
  rescue
    error -> Logger.warning("StudioMix: v1 migration failed: #{Exception.message(error)}")
  end

  # True when the entry is dealt with (moved, or not ours to move).
  defp move_v1_file(old_dir, name) do
    if String.ends_with?(name, @v1_ext) do
      dest = Path.join(dir(), String.replace_suffix(name, @v1_ext, @ext))
      not File.exists?(dest) and File.rename(Path.join(old_dir, name), dest) == :ok
    else
      false
    end
  end

  @doc "Sorted names of every saved mix."
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

  @doc "Whether a mix by this name exists."
  def exists?(name) when is_binary(name), do: name in list()

  @doc """
  Create and save a new mix under a safe, collision-free name. Returns the
  name actually used, which may carry a `-2` suffix.
  """
  def create(requested) when is_binary(requested) do
    case safe_mix_name(requested) do
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

  @doc "Read a mix by name."
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

  @doc "Write an mix to disk."
  def save(%__MODULE__{name: name} = mix) when is_binary(name) do
    File.mkdir_p(dir())

    case File.write(path_for(name), Jason.encode!(to_map(mix), pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rename a saved mix. The name lives in two places — the filename and the
  `"name"` inside — and both move, because a file whose contents disagree with
  it is the kind of thing that only surfaces months later.
  """
  def rename(name, requested) when is_binary(name) and is_binary(requested) do
    with true <- exists?(name),
         {:ok, base} <- safe_mix_name(requested),
         false <- exists?(base),
         {:ok, mix} <- load(name),
         :ok <- save(%{mix | name: base}),
         :ok <- File.rm(path_for(name)) do
      {:ok, base}
    else
      false -> {:error, :not_found}
      true -> {:error, :name_taken}
      {:error, _reason} = error -> error
    end
  end

  def rename(_name, _requested), do: {:error, :not_found}

  @doc """
  Repoint every clip that referenced `old_source` at `new_source`, across every
  saved mix. Returns the number of mixes actually rewritten.

  This is the other half of renaming a *file*. A clip stores a catalog id
  (`"import:cut.wav"`), never a path — which is what makes a mix survive its
  sources being re-edited, and exactly what makes a rename able to orphan one.
  A missing source fails a render loudly and by design; a rename is not a
  disappearance, so it must not look like one.
  """
  def retarget(old_source, new_source) when is_binary(old_source) and is_binary(new_source) do
    Enum.count(list(), fn name ->
      with {:ok, mix} <- load(name),
           true <- Enum.any?(clips(mix), fn {_track, clip} -> clip.source == old_source end) do
        mix |> replace_source(old_source, new_source) |> save() == :ok
      else
        _ -> false
      end
    end)
  end

  defp replace_source(%__MODULE__{tracks: tracks} = mix, old, new) do
    retargeted =
      Enum.map(tracks, fn track ->
        %{
          track
          | clips:
              Enum.map(track.clips, fn clip ->
                if clip.source == old, do: %{clip | source: new}, else: clip
              end)
        }
      end)

    %{mix | tracks: retargeted}
  end

  @doc "Delete a saved mix. The clips it referenced are untouched."
  def delete(name) when is_binary(name) do
    if exists?(name), do: File.rm(path_for(name)), else: {:error, :not_found}
  end

  defp path_for(name), do: Path.join(dir(), name <> @ext)

  # An mix name must carry at least one letter or digit. The check is on the
  # REQUEST, not on the sanitized result, because `Music.safe_name/1`
  # substitutes "track" for anything that reduces to nothing — so a check on its
  # output could never fire, and `"   "` would quietly become a mix called
  # "track". Reusing that sanitizer is still right for everything after: it is
  # the one that already knows how to reduce `../../etc/evil` to a basename.
  defp safe_mix_name(requested) do
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
  # JSON. Writes v2 ("tracks"); reads v2 and v1 ("lanes"). These functions are
  # the entire translation layer; see the moduledoc.
  # ---------------------------------------------------------------------------

  defp to_map(%__MODULE__{} = mix) do
    %{
      "version" => 2,
      "name" => mix.name,
      "tracks" =>
        Enum.map(mix.tracks, fn track ->
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
                  # Written through `window/1` rather than `clip.offset_ms` so a
                  # clip loaded from a pre-08-16 file — which has no such key —
                  # can be saved again without raising.
                  "offset_ms" => elem(window(clip), 0),
                  "duration_ms" => clip.duration_ms,
                  "effects" =>
                    Enum.map(chain(clip), fn effect ->
                      %{"type" => effect.type, "params" => effect.params}
                    end)
                }
              end)
          }
        end)
    }
  end

  # Tolerant by design: this file is in the operator's workspace and they are
  # invited to edit it. A malformed track is dropped, not a parse error that
  # makes the whole mix unopenable.
  defp from_map(name, %{"tracks" => rows}) when is_list(rows), do: build(name, rows)

  # v1 said "lanes". Still read, so a hand-copied old file opens; the next save
  # writes it back as v2.
  defp from_map(name, %{"lanes" => rows}) when is_list(rows), do: build(name, rows)

  defp from_map(name, _other), do: new(name)

  defp build(name, rows) do
    parsed = rows |> Enum.map(&parse_track/1) |> Enum.reject(&is_nil/1)
    %__MODULE__{name: name, tracks: if(parsed == [], do: [track(0)], else: parsed)}
  end

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
      # Absent in every mix written before trim existed, and `0` is the correct
      # reading for those: they start at the beginning of their source.
      offset_ms: max(0.0, Map.get(clip, "offset_ms", 0) * 1.0),
      duration_ms: max(0.0, Map.get(clip, "duration_ms", 0) * 1.0),
      effects: parse_effects(Map.get(clip, "effects"))
    }
  end

  defp parse_clip(_clip), do: nil

  # Same tolerance as everything else in this file: the mix is hand-editable, so
  # an effect naming a type that does not exist is DROPPED rather than making the
  # mix unopenable. `Effects.apply_chain/2` would skip it anyway; dropping it here
  # means the next save writes a file that says what will actually happen.
  defp parse_effects(rows) when is_list(rows) do
    rows
    |> Enum.flat_map(fn
      %{"type" => type} = row when is_binary(type) ->
        case Effects.build(type) do
          {:ok, effect} -> [restore_params(effect, Map.get(row, "params"))]
          :error -> []
        end

      _other ->
        []
    end)
  end

  defp parse_effects(_rows), do: []

  # Params go back through `put_param/3`, so a hand-written value out of range is
  # clamped on the way IN rather than trusted and clamped later.
  defp restore_params(effect, params) when is_map(params) do
    Enum.reduce(params, effect, fn {key, value}, acc -> Effects.put_param(acc, key, value) end)
  end

  defp restore_params(effect, _params), do: effect
end
