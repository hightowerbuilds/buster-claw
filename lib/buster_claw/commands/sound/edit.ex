defmodule BusterClaw.Commands.Sound.Edit do
  @moduledoc """
  The sound **editing** verbs — `sound_import` and the four edits
  (`sound_trim`, `sound_fade`, `sound_normalize`, `sound_concat`).

  Every one writes a NEW studio source and routes nothing, which is why they
  are `:restricted` but not gated: editing in place would destroy a recording
  that cannot be re-recorded, and a render to a new file is reviewable in a way
  an in-place mutation is not. Each returns `duration_ms` and `peak` beside
  the source's own — the agent cannot hear, so those two numbers are how it
  checks that a cut cut something. Split out of `BusterClaw.Commands.Sound` on
  10-16 (CODE_QUALITY_SWEEP Phase 6); see that module for the surface's story.
  """
  alias BusterClaw.Commands.Sound.Shared
  alias BusterClaw.Notifications.SoundStudio

  # ---------------------------------------------------------------------------
  # Import — the door into the studio
  # ---------------------------------------------------------------------------

  def sound_import(args) when is_map(args) do
    overwrite? = Shared.boolean(Map.get(args, "overwrite"), false)

    with {:ok, origin} <- Shared.import_origin(args),
         {:ok, target} <-
           Shared.stored_name(Shared.blank_to_nil(Map.get(args, "name")) || origin.name),
         {:ok, path, replaced?} <- studio_target(target, overwrite?),
         {:ok, clip, decoded?} <- import_clip(origin.path),
         :ok <- write_source(clip, path) do
      {:ok,
       %{
         name: target,
         path: path,
         event_id: origin.event_id,
         library_path: origin.relative,
         duration_ms: SoundStudio.duration_ms(clip),
         sample_rate: clip.sample_rate,
         channels: clip.channels,
         bits: clip.bits,
         peak: Shared.peak_of(clip),
         internal: SoundStudio.internal?(clip),
         internal_format: Shared.internal_format(),
         decoded: decoded?,
         decoder_available: SoundStudio.decoder_available?(),
         bytes: Shared.byte_size_of(path),
         replaced: replaced?,
         notes: import_notes(decoded?, replaced?)
       }}
    end
  end

  def sound_import(_args), do: {:error, :missing_source}

  # `import_source/1` is the one door to the outside world and decides for
  # itself whether the decoder is needed. Asking it the same question first is
  # the only way to *report* which path it took — and whether the decoder ran is
  # exactly what a caller needs to know when the answer on another machine
  # would have been a refusal.
  defp import_clip(path) do
    decoded? = not already_internal?(path)

    case SoundStudio.import_source(path) do
      {:ok, clip} -> {:ok, clip, decoded?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp already_internal?(path) do
    case SoundStudio.read(path) do
      {:ok, clip} -> SoundStudio.internal?(clip)
      {:error, _reason} -> false
    end
  end

  defp import_notes(decoded?, replaced?) do
    [
      "Stored in sounds/studio/ as a SOURCE — raw material. It is not in the sound library and nothing is routed to it; probe it, cut it, and route it as separate deliberate acts.",
      if(decoded?,
        do:
          "The system decoder ran, so the stored clip was resampled and downmixed to PCM16 mono 22.05 kHz. Its peak is the peak of that conversion, which is the clip an edit will operate on."
      ),
      if(replaced?, do: "An existing source of this name was overwritten.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Editing — one pure function each, rendered to a new source
  # ---------------------------------------------------------------------------

  def sound_trim(%{"source" => source} = args) when is_binary(source) do
    with {:ok, from, to} <- span(args) do
      edit(args, "trim", fn clip ->
        # `end_ms` resolves against the clip, which is the one part of the span
        # that cannot be checked before the audio is open.
        to = to || SoundStudio.duration_ms(clip)

        with {:ok, cut} <- SoundStudio.splice(clip, from, to) do
          {:ok, cut, %{start_ms: from, end_ms: to}}
        end
      end)
    end
  end

  def sound_trim(_args), do: {:error, :missing_source}

  # `end_ms` defaults to the end of the clip and `start_ms` to 0, so trimming a
  # tail is one argument. `splice/3` clamps out-of-range values to the clip and
  # refuses a span that ends at or before it starts, which is what a span
  # entirely past the end collapses to — reported as :empty_selection rather
  # than as a zero-length file.
  defp span(args) do
    from = Map.get(args, "start_ms")
    to = Map.get(args, "end_ms")

    cond do
      not (is_nil(from) or is_number(from)) -> {:error, :invalid_span}
      not (is_nil(to) or is_number(to)) -> {:error, :invalid_span}
      is_number(from) and from < 0 -> {:error, :invalid_span}
      true -> {:ok, from || 0, to}
    end
  end

  def sound_fade(%{"source" => source} = args) when is_binary(source) do
    with {:ok, in_ms, out_ms} <- ramps(args) do
      edit(args, "fade", fn clip ->
        {:ok, SoundStudio.fade(clip, in_ms: in_ms, out_ms: out_ms),
         %{in_ms: in_ms, out_ms: out_ms}}
      end)
    end
  end

  def sound_fade(_args), do: {:error, :missing_source}

  # A fade with neither ramp given is refused rather than silently written: it
  # would render a byte-identical copy under a new name, which reads as the verb
  # having done something when it did not.
  defp ramps(args) do
    in_ms = Map.get(args, "in_ms")
    out_ms = Map.get(args, "out_ms")

    cond do
      is_nil(in_ms) and is_nil(out_ms) -> {:error, :missing_fade}
      not (is_nil(in_ms) or is_number(in_ms)) -> {:error, :invalid_fade}
      not (is_nil(out_ms) or is_number(out_ms)) -> {:error, :invalid_fade}
      (in_ms || 0) < 0 or (out_ms || 0) < 0 -> {:error, :invalid_fade}
      true -> {:ok, in_ms || 0, out_ms || 0}
    end
  end

  def sound_normalize(%{"source" => source} = args) when is_binary(source) do
    with {:ok, target} <- normalize_target(args) do
      edit(args, "normalize", fn clip ->
        levelled =
          if target, do: SoundStudio.normalize(clip, target), else: SoundStudio.normalize(clip)

        # `target` is nil when the module's own default was used, so the number
        # that says what actually happened is `peak` beside `source_peak` — and
        # on digital silence they are both 0.0, because there is no gain that
        # makes zero louder.
        {:ok, levelled, %{target: target}}
      end)
    end
  end

  def sound_normalize(_args), do: {:error, :missing_source}

  # A target above 1.0 is not a louder sound, it is a clipped one — the samples
  # clamp at full scale — so it is refused rather than obeyed.
  defp normalize_target(args) do
    case Map.get(args, "target") do
      nil -> {:ok, nil}
      target when is_number(target) and target > 0 and target <= 1.0 -> {:ok, target}
      _other -> {:error, :invalid_target}
    end
  end

  def sound_concat(%{"sources" => sources, "name" => name} = args)
      when is_list(sources) and is_binary(name) do
    overwrite? = Shared.boolean(Map.get(args, "overwrite"), false)

    with {:ok, target} <- Shared.stored_name(name),
         {:ok, path, replaced?} <- studio_target(target, overwrite?),
         {:ok, loaded} <- concat_sources(sources),
         {:ok, joined} <- SoundStudio.concat(Enum.map(loaded, & &1.clip)),
         :ok <- write_source(joined, path) do
      {:ok,
       %{
         name: target,
         path: path,
         sources: Enum.map(loaded, &Map.take(&1, [:name, :duration_ms, :peak])),
         duration_ms: SoundStudio.duration_ms(joined),
         peak: Shared.peak_of(joined),
         bytes: Shared.byte_size_of(path),
         replaced: replaced?,
         notes:
           new_source_notes(replaced?) ++
             [
               "Joined end to end with no gap and no fade: every seam is a hard cut, which is the loudest click a join can make. Use this for whole clips that already end quietly, or sound_fade each piece first."
             ]
       }}
    end
  end

  def sound_concat(%{"sources" => sources}) when is_list(sources), do: {:error, :missing_name}
  def sound_concat(_args), do: {:error, :empty_selection}

  # Order is the caller's, exactly as given — a concat is an arrangement, and
  # sorting or de-duplicating it would silently change what was asked for. A
  # source named twice is joined twice, on purpose.
  defp concat_sources([]), do: {:error, :empty_selection}

  defp concat_sources(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
      case load_source(source) do
        {:ok, loaded} -> {:cont, {:ok, [loaded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, _reason} = error -> error
    end
  end

  defp load_source(source) when is_binary(source) do
    with {:ok, name} <- Shared.validate_name(source),
         {:ok, path} <- Shared.studio_source(name),
         {:ok, clip} <- Shared.editable_clip(path) do
      {:ok,
       %{
         name: name,
         clip: clip,
         duration_ms: SoundStudio.duration_ms(clip),
         peak: Shared.peak_of(clip)
       }}
    end
  end

  defp load_source(_source), do: {:error, :invalid_name}

  # The shape every single-source edit has: resolve the source, refuse the
  # output name BEFORE doing the work, run one pure function, write the result.
  #
  # The name check sits ahead of the edit deliberately: a refusal to clobber
  # should cost nothing, and discovering it after a full render is how a caller
  # learns to pass `overwrite: true` reflexively.
  #
  # Which is why **each verb validates its own arguments before calling this**,
  # rather than inside `fun`. A bad `start_ms` reported as `:name_taken` because
  # the previous run of the same verb already took the derived name is a
  # genuinely misleading error, and it is what the ordering here would otherwise
  # produce.
  defp edit(args, verb, fun) do
    overwrite? = Shared.boolean(Map.get(args, "overwrite"), false)
    given = Shared.blank_to_nil(Map.get(args, "name"))

    with {:ok, source} <- Shared.validate_name(Map.get(args, "source")),
         {:ok, path} <- Shared.studio_source(source),
         {:ok, clip} <- Shared.editable_clip(path),
         {:ok, target} <- Shared.stored_name(given || derived_name(source, verb)),
         {:ok, out, replaced?} <- studio_target(target, overwrite?),
         {:ok, edited, extra} <- fun.(clip),
         :ok <- write_source(edited, out) do
      {:ok, edit_result(source, clip, target, out, edited, replaced?, extra)}
    end
  end

  # With no name given, the output is named after its input — `harbor.wav`
  # trimmed becomes `harbor-trim.wav`. Derived rather than required so a chain of
  # edits reads as one thought, and colliding with a previous run of the same
  # verb is a plain :name_taken rather than a silent overwrite.
  defp derived_name(source, verb), do: Path.rootname(source) <> "-" <> verb <> ".wav"

  # Both sides of the edit, because the agent cannot hear: the source's duration
  # and peak beside the result's are the whole of how it verifies that a trim
  # removed audio and a normalize moved a level.
  defp edit_result(source, clip, target, path, edited, replaced?, extra) do
    Map.merge(
      %{
        name: target,
        path: path,
        source: source,
        source_duration_ms: SoundStudio.duration_ms(clip),
        source_peak: Shared.peak_of(clip),
        duration_ms: SoundStudio.duration_ms(edited),
        peak: Shared.peak_of(edited),
        bytes: Shared.byte_size_of(path),
        replaced: replaced?,
        notes: new_source_notes(replaced?)
      },
      extra
    )
  end

  defp new_source_notes(replaced?) do
    [
      "Written into sounds/studio/ as a new SOURCE. It is not in the sound library and nothing is routed to it — sound_apply is the verb that installs a source as a chime and points a key at it.",
      if(replaced?, do: "An existing source of this name was overwritten.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # An edit that clobbers the recording it was cut from is unrecoverable, so an
  # existing name is refused unless the caller says overwrite. `File.exists?/1`
  # rather than the audio listing, so a non-audio file squatting the name is
  # still protected.
  defp studio_target(target, overwrite?) do
    path = Path.join(SoundStudio.dir(), target)
    exists? = File.exists?(path)

    cond do
      not exists? -> {:ok, path, false}
      overwrite? -> {:ok, path, true}
      true -> {:error, :name_taken}
    end
  end

  defp write_source(clip, path) do
    File.mkdir_p(SoundStudio.dir())
    SoundStudio.write(clip, path)
  end
end
