defmodule BusterClawWeb.SoundStudio.Edits do
  @moduledoc """
  The Mix tab's socket-free edit operations — measuring a source, cutting one,
  and turning a failure into a sentence.

  Extracted from `SoundStudioComponent` on 08-16, and the reason is the point:
  that file was **FROZEN** in `scripts/check_file_sizes.sh`, so the clip-trim
  feature could not be paid for with a raised cap. It had to be funded by taking
  something out, and the 08-13 review had already named this block as the better
  second cut of the frozen Phase 3 — *"the render/trim/rename block, socket-free
  `{:ok,_}` / `{:error,_}` functions"*.

  **That was the third time the freeze produced an extraction rather than
  growth, and the last.** The tier was lifted to HELD hours later, once Phase 3
  — the phase it was frozen for — had been taken. This module is one of the
  three things that exist because of it, which is the argument the tier had.

  Everything here takes plain values and returns plain values. No socket, no
  assigns — which is also why it is testable without mounting anything.

  ## `apply_trim/2` cuts a FILE. `StudioMix.trim_clip/4` does not.

  Worth stating together, because the app now has two things called trim and
  they are opposites. This one splices audio and writes a **new source** to the
  studio folder. The clip trim narrows a clip's window into a source it never
  touches. A reader who conflates them will expect one to be undoable and the
  other to be safe, and will be wrong both ways.
  """
  import BusterClawWeb.SoundStudio.Catalog

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.Studio.Render
  alias BusterClaw.Notifications.StudioMix

  def measured_duration(source) do
    case clip_duration(source) do
      {:ok, ms} -> ms
      {:error, _reason} -> nil
    end
  end

  @doc "Coerce a form value to milliseconds; junk and blanks are 0."
  def to_ms(value) when is_number(value), do: value

  def to_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0.0
    end
  end

  def to_ms(_value), do: 0.0

  def clip_duration(source) do
    case resolve_source(source) do
      %{path: path} when is_binary(path) ->
        case SoundStudio.probe(path) do
          {:ok, %{duration_ms: ms}} -> {:ok, ms}
          {:error, _reason} -> decoded_duration(path)
        end

      # No source, or one with no file behind it (an arrangement).
      _other ->
        {:error, :enoent}
    end
  end

  def decoded_duration(path) do
    case SoundStudio.import_source(path) do
      {:ok, clip} -> {:ok, SoundStudio.duration_ms(clip)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The mixdown and the effect chain live in `Studio.Render` — this file is
  # FROZEN at the time and could not hold them — the size gate earning its keep.
  #
  # **The catalog is read ONCE and closed over**, not per clip. It used to pass
  # `&resolve_source/1`, which calls `groups/0` fresh every time Render asks —
  # and `groups/0` is four directory listings plus a database query. An n-clip
  # mixdown therefore did n of them. Filed by the 08-13 review, fixed here
  # because the extraction is what made the two costs visible as different
  # things: `groups/0` is the expensive read, `find_source/2` is the cheap
  # lookup over a result you already have.
  def render_mix(%StudioMix{} = mix) do
    catalog = groups()
    Render.install(mix, &find_source(catalog, &1))
  end

  def apply_trim(nil, _trim), do: {:error, :no_selection}
  def apply_trim(_selected, nil), do: {:error, :no_selection}
  def apply_trim(%{path: nil}, _trim), do: {:error, :enoent}

  def apply_trim(%{path: path, name: name}, %{from_ms: from, to_ms: to}) do
    with {:ok, clip} <- SoundStudio.import_source(path),
         {:ok, cut} <- SoundStudio.splice(clip, from, to) do
      # A cut from the middle of a file starts and ends mid-waveform, and a
      # mid-waveform edge is a step from silence to full amplitude — the loudest
      # click a sound can have. These two ramps are DE-CLICKING, not shaping;
      # the fade tool (next) is the one that shapes.
      cut
      |> SoundStudio.fade(in_ms: 2, out_ms: 6)
      |> SoundStudio.save(Path.rootname(name) <> "-trim")
    end
  end

  def trim_error(:empty_selection), do: "That selection is empty."
  def trim_error(:no_selection), do: "Select part of the waveform first."
  def trim_error(:unsupported_source), do: "Couldn't decode this file to trim it."
  def trim_error(:no_decoder), do: "The system decoder is unavailable."
  def trim_error(_other), do: "Couldn't save the trim."

  # A rejected file that does not say WHY is a support question, and "we tried
  # to decode it and could not" is a real answer.
  def import_error(:unsupported_format), do: "Audio files only (MP3, M4A, AAC, WAV, OGG, FLAC)."
  def import_error(:not_audio), do: "That file couldn't be decoded, whatever it is named."
  def import_error(:enoent), do: "The upload didn't arrive."
  def import_error(_other), do: "Couldn't import that file."
end
