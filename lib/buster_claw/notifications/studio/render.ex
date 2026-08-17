defmodule BusterClaw.Notifications.Studio.Render do
  @moduledoc """
  Turning an arrangement into audio — the mixdown, and the effect chain on the
  way through.

  Extracted from `SoundStudioComponent` on 08-16. It lived in the LiveView
  because it was three short functions with nowhere better to be; effects gave it
  somewhere. The component is `FROZEN` in `check_file_sizes.sh` and could not
  have grown to hold this, which is the gate doing exactly what it is for.

  Being domain code rather than LiveView code buys two things immediately: the
  render is testable without mounting anything, and `preview/2` — hearing ONE
  clip with its effects — is a function rather than a second copy of the pipeline.

  ## The order of operations, and why it is this one

      source file
        └─ import_source     decode to the studio's internal format
        └─ apply_chain       the clip's effects, in the operator's order
        └─ mixdown           sum every audible clip at its offset

  Effects are applied **per clip, before the sum**. That is the only order that
  makes sense of a per-clip chain: reverb on one clip must not wash the whole
  arrangement, and reversing one clip must not reverse the mix.

  ## Three refusals, and why each is whole-render rather than partial

  `:empty_mix`, `:all_silenced` and `:missing_source` all abandon the entire
  render. The last is the interesting one: a clip whose source was deleted or
  renamed could simply be skipped, and that is worse. **A mix missing one layer
  still sounds finished**, so the operator would ship it without ever learning
  what was lost. Refusing is the only way the absence is legible.
  """

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.Studio.Effects
  alias BusterClaw.Notifications.StudioMix

  @typedoc "Why a render was refused."
  @type error :: :empty_mix | :all_silenced | :missing_source | term()

  @doc """
  Render every audible clip of a mix into one clip.

  `resolve` maps a clip's `source` string to `%{path: path}` (or anything else,
  which reads as missing). It is passed in rather than imported because source
  resolution spans the library, the studio folder and the music library, and that
  knowledge belongs to the surface that owns those lists — not here.
  """
  @spec mixdown(StudioMix.t(), (String.t() -> term())) ::
          {:ok, SoundStudio.t()} | {:error, error()}
  def mixdown(%StudioMix{} = mix, resolve) when is_function(resolve, 1) do
    # Audible clips only: the render must be what the arranger SHOWS it will be,
    # and a muted track that still rendered would make M a lie with a UI.
    placements =
      mix
      |> StudioMix.audible_clips()
      |> Enum.map(fn {_track, clip} -> placement(clip, resolve) end)

    cond do
      StudioMix.clips(mix) == [] ->
        {:error, :empty_mix}

      # Clips exist but mute/solo silenced every one — a different mistake than
      # an empty arrangement, deserving a different sentence.
      placements == [] ->
        {:error, :all_silenced}

      Enum.any?(placements, &match?({:error, _}, &1)) ->
        {:error, :missing_source}

      true ->
        SoundStudio.mixdown(Enum.map(placements, fn {:ok, p} -> p end))
    end
  end

  @doc """
  Render ONE clip with its effects — what the operator hears when auditioning a
  chain.

  The same `import_source` and the same `apply_chain/2` the full render uses, so
  a preview cannot disagree with the mixdown about what an effect does. That is
  the whole reason this is a function here rather than a WebAudio approximation
  in the browser: reverb has no client-side equivalent, and half a chain
  previewed accurately is more misleading than none.
  """
  @spec preview(map(), (String.t() -> term())) ::
          {:ok, SoundStudio.t()} | {:error, :missing_source}
  def preview(clip, resolve) when is_function(resolve, 1) do
    case placement(clip, resolve) do
      {:ok, {audio, _offset}} -> {:ok, audio}
      {:error, _source} -> {:error, :missing_source}
    end
  end

  @doc """
  Render a mix and install it in the library as `<name>-mix.wav`.

  A render lands in `sounds/` — the library — not in `sounds/studio/`. The two
  folders mean different things: `studio/` is what you are working ON, `sounds/`
  is what the app will play. A render is the finished thing, so this is where it
  belongs, and putting it here is what makes it appear in Settings → Notify's
  list with no further step. Nothing is lost by not also keeping a `studio/`
  copy: library sounds are addable as clips, so a render can still be a layer in
  the next mix.

  Via a temp file so `Sound.install_file/2` stays the single door into the
  library — it owns the never-overwrite rule, which matters here because this
  layer shadows bundled chimes by basename.
  """
  @spec install(StudioMix.t(), (String.t() -> term())) :: {:ok, String.t()} | {:error, error()}
  def install(%StudioMix{} = mix, resolve) when is_function(resolve, 1) do
    with {:ok, mixed} <- mixdown(mix, resolve) do
      tmp = Path.join(System.tmp_dir!(), "bc-render-#{:erlang.unique_integer([:positive])}.wav")

      try do
        with :ok <- File.write(tmp, SoundStudio.render(mixed)) do
          Sound.install_file(tmp, Path.rootname(mix.name <> "-mix") <> ".wav")
        end
      after
        File.rm(tmp)
      end
    end
  end

  # One clip, windowed, effected, paired with where it starts.
  #
  # NOTE the offset is the clip's declared `start_ms` and nothing here adjusts
  # it for length changes. An effect may make the audio longer or shorter than
  # the block on the timeline (`Studio.Effects` says why), and `SoundStudio.mixdown/1`
  # sums overlaps — so a reverb tail bleeding into the next clip is correct
  # rather than a bug to correct.
  #
  # ## The window is applied here, and until 08-16 it was not applied anywhere
  #
  # This decoded the WHOLE source and placed it at `start_ms`; `duration_ms` was
  # the block's width on the ruler and nothing else. A clip that looked 800 ms
  # long rendered its entire five-minute file, silently, and only the mixdown
  # told you.
  #
  # It was invisible because `add_clip/5` sets `duration_ms` to the source's own
  # measured length, so for every clip that existed the window was the whole
  # file and cutting to it changes nothing. **That is what made honouring it
  # safe** — the fix is a no-op on every mix written before trim existed.
  #
  # The window is cut BEFORE effects, which is the ordering that matches what
  # the operator sees: they trimmed a clip and then shaped it. Effecting first
  # and cutting after would mean a reverb applied to audio the mix never uses.
  defp placement(clip, resolve) do
    {offset_ms, duration_ms} = StudioMix.window(clip)

    with %{path: path} when is_binary(path) <- resolve.(clip.source),
         {:ok, decoded} <- SoundStudio.import_source(path),
         {:ok, windowed} <- SoundStudio.splice(decoded, offset_ms, offset_ms + duration_ms) do
      {:ok, {Effects.apply_chain(windowed, StudioMix.chain(clip)), clip.start_ms}}
    else
      _ -> {:error, clip.source}
    end
  end
end
