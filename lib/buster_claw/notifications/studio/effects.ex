defmodule BusterClaw.Notifications.Studio.Effects do
  @moduledoc """
  What can be done to a clip, and how — the Studio's effect chain.

  A clip in a mix carries an **ordered list** of effects. This module is the one
  place that knows what an effect is called, what it can be given, and what it
  does to audio. The arranger renders from `catalog/0`, the renderer calls
  `apply_chain/2`, and neither knows the name of a single effect.

  That indirection is the whole point of the file. Adding an effect is:

    1. a `@catalog` entry declaring its params, ranges and defaults, and
    2. a clause of `apply_one/2`.

  Nothing in the UI, the mix format, or the renderer changes.

  ## Three properties every effect must hold

  These are not style; each one is a bug the chain would otherwise grow.

  **Total.** `apply_one/2` never raises and never returns an error. An effect
  handed a parameter it dislikes clamps it and proceeds. A render that fails
  halfway leaves a mix the operator cannot fix without knowing which clip broke,
  and "your reverb was 0.02 too wet" is not a thing anyone can act on.

  **Format-preserving.** Sample rate, channel count and bit depth go in and come
  out unchanged. `SoundStudio.mixdown/1` refuses clips that disagree on format,
  so an effect that resampled would turn one bad parameter into `:format_mismatch`
  on the whole arrangement.

  **Length-free.** An effect MAY change the length, and that is deliberate rather
  than tolerated — see below.

  ## Effects may change length, and the arrangement does not chase it

  Reverb adds a tail. Speed makes a clip shorter or longer. So a clip's
  `duration_ms` in the arrangement means **how much of the source was taken**,
  not how long its contribution will sound.

  The alternative — re-deriving `duration_ms` after every parameter change — was
  rejected: it makes the arranger jump under the operator while they drag a
  slider, and it makes an effect's *undo* move clips. `SoundStudio.mixdown/1`
  sums overlapping audio, so a reverb tail bleeding into the next clip is
  correct: that is what a reverb tail does on a real desk.

  What that costs, stated plainly: the block you see on the timeline is where the
  clip *starts* and how much source it uses. With a long tail it is not where the
  sound stops. The arranger says so rather than drawing a lie.

  ## Why these are not `SoundStudio` functions

  `SoundStudio` owns the format — parse, render, splice, fade, mixdown — and is
  called by the cut-up engine, the chime designer and the recorder. Effects are a
  *mix* concept: they exist because a clip sits in an arrangement. Putting them
  there would make the file every audio caller depends on grow for a feature only
  one of them uses.
  """

  alias BusterClaw.Notifications.SoundStudio

  @typedoc "One effect in a chain: a known type and its parameters."
  @type effect :: %{type: String.t(), params: %{String.t() => number()}}

  # The catalog. `params` declares `{min, max, default}` per control, which is
  # everything the UI needs to render a slider and everything `clamp/2` needs to
  # keep a hand-edited mix file from reaching the DSP with nonsense in it.
  #
  # `label` is what the operator reads; `blurb` is the one line that says what it
  # does to the sound, because "wet 0.3" means nothing to someone who has not
  # used a reverb before.
  @catalog [
    %{
      type: "reverse",
      label: "Reverse",
      blurb: "Play the clip backwards. Exact — reversing twice returns the original.",
      params: %{}
    },
    %{
      type: "gain",
      label: "Gain",
      blurb: "Louder or quieter. Clamps at full scale rather than wrapping.",
      params: %{"amount" => {0.0, 4.0, 1.0}}
    },
    %{
      type: "speed",
      label: "Speed",
      blurb:
        "Faster or slower, and the pitch moves with it — this is tape varispeed, " <>
          "not a pitch shifter. 2.0 is an octave up and half as long.",
      params: %{"rate" => {0.25, 4.0, 1.0}}
    },
    %{
      type: "reverb",
      label: "Reverb",
      blurb: "A room around the clip. Adds a tail, so it sounds past its block on the timeline.",
      params: %{
        "size" => {0.0, 1.0, 0.5},
        "mix" => {0.0, 1.0, 0.3}
      }
    }
  ]

  @types Enum.map(@catalog, & &1.type)

  @doc "Every effect that can be added, in the order the UI offers them."
  @spec catalog() :: [map()]
  def catalog, do: @catalog

  @doc "The effect types that exist."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "Whether a type is real."
  @spec known?(term()) :: boolean()
  def known?(type) when is_binary(type), do: type in @types
  def known?(_type), do: false

  @doc "The catalog entry for a type, or `nil`."
  @spec entry(term()) :: map() | nil
  def entry(type) when is_binary(type), do: Enum.find(@catalog, &(&1.type == type))
  def entry(_type), do: nil

  @doc """
  Build an effect of `type` with its defaults, or `:error` for an unknown one.

  Refusing an unknown type here is what keeps `apply_chain/2` total: nothing that
  cannot be applied ever reaches a mix file.
  """
  @spec build(term()) :: {:ok, effect()} | :error
  def build(type) do
    case entry(type) do
      nil -> :error
      %{params: params} -> {:ok, %{type: type, params: defaults(params)}}
    end
  end

  @doc """
  Set one parameter, clamped to its declared range.

  An unknown effect or an unknown parameter returns the effect unchanged rather
  than raising: this is reached from a socket event, and a stale client should
  not be able to crash a render.
  """
  @spec put_param(effect(), term(), term()) :: effect()
  def put_param(%{type: type, params: params} = effect, key, value) do
    with %{params: declared} <- entry(type),
         {_min, _max, _default} = range <- Map.get(declared, key),
         numeric when is_number(numeric) <- numeric(value) do
      %{effect | params: Map.put(params, key, clamp(numeric, range))}
    else
      _other -> effect
    end
  end

  def put_param(effect, _key, _value), do: effect

  @doc """
  Apply a whole chain, in order.

  Order is significant and is the operator's: reverb-then-reverse is a swell into
  the note, reverse-then-reverb is a note with a tail. Sorting or normalising the
  chain would destroy a real musical distinction.

  Total by construction — an unknown type is skipped, so a mix file edited by
  hand renders rather than refusing.
  """
  @spec apply_chain(SoundStudio.t(), [effect()] | nil) :: SoundStudio.t()
  def apply_chain(%SoundStudio{} = clip, nil), do: clip
  def apply_chain(%SoundStudio{} = clip, []), do: clip

  def apply_chain(%SoundStudio{} = clip, effects) when is_list(effects) do
    Enum.reduce(effects, clip, fn effect, acc -> apply_one(acc, effect) end)
  end

  def apply_chain(%SoundStudio{} = clip, _effects), do: clip

  @doc """
  Apply one effect. Never raises; an unknown type is the identity.

  Every clause below reads and writes 16-bit mono/stereo PCM through
  `SoundStudio`'s own accessors, so the format contract holds by construction.
  """
  @spec apply_one(SoundStudio.t(), term()) :: SoundStudio.t()
  def apply_one(%SoundStudio{} = clip, %{type: "reverse"}), do: reverse(clip)

  def apply_one(%SoundStudio{} = clip, %{type: "gain"} = effect),
    do: gain(clip, param(effect, "amount"))

  def apply_one(%SoundStudio{} = clip, %{type: "speed"} = effect),
    do: speed(clip, param(effect, "rate"))

  def apply_one(%SoundStudio{} = clip, %{type: "reverb"} = effect),
    do: reverb(clip, param(effect, "size"), param(effect, "mix"))

  def apply_one(%SoundStudio{} = clip, _unknown), do: clip

  # ---------------------------------------------------------------------------
  # The effects themselves
  # ---------------------------------------------------------------------------

  # Sample-wise reversal. Exact and lossless: no arithmetic touches the values,
  # so `reverse(reverse(x)) == x` byte for byte, which is what its test asserts.
  defp reverse(clip) do
    reversed =
      clip.data
      |> chunk_frames(SoundStudio.frame_bytes(clip))
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    %{clip | data: reversed}
  end

  # Clamped rather than wrapped. A sample multiplied past the rail must saturate:
  # int16 wrapping turns the loudest moment of a clip into the harshest possible
  # click, which is exactly where it is least forgivable.
  defp gain(clip, amount) do
    SoundStudio.map_samples(clip, fn s, _i -> s * amount end)
  end

  # Varispeed: resample by a ratio, so pitch and duration move together. This is
  # what a tape machine does and it is NOT a pitch shifter — holding duration
  # while moving pitch needs a phase vocoder, which is a different feature and
  # should arrive as its own catalog entry rather than as an option here.
  #
  # Linear interpolation between neighbours. Honest limitation: speeding up
  # aliases, because there is no anti-alias filter in front of the decimation.
  # Below 2.0 on speech it is not audible; the fix, if it ever matters, is a
  # low-pass before the resample and belongs here rather than in the caller.
  defp speed(clip, rate) when rate > 0 do
    source = SoundStudio.samples(clip.data)
    count = length(source)
    table = List.to_tuple(source)
    target = max(trunc(count / rate), 1)

    resampled =
      for i <- 0..(target - 1), into: <<>> do
        pos = i * rate
        left = trunc(pos)
        frac = pos - left

        a = at(table, left, count)
        b = at(table, left + 1, count)

        <<SoundStudio.clamp16(a + (b - a) * frac)::little-signed-16>>
      end

    %{clip | data: resampled}
  end

  defp speed(clip, _rate), do: clip

  # A Schroeder reverb: parallel feedback combs into a series allpass. Small,
  # well understood, and enough of a room to be worth having; it is not a
  # convolution reverb and does not pretend to be.
  #
  # The tail is REAL LENGTH — the clip grows by the decay time. That is the
  # length-free property in the moduledoc doing its job, and it is why a reverbed
  # clip sounds past its block on the timeline.
  defp reverb(clip, _size, mix) when mix <= 0.0, do: clip

  defp reverb(clip, size, mix) do
    rate = clip.sample_rate
    # 0..1 maps to a small room .. a large one. The four comb delays are the
    # classic mutually-prime-ish spread, scaled by size so they stay uncorrelated.
    scale = 0.5 + size
    delays = Enum.map([1116, 1188, 1277, 1356], &max(trunc(&1 * scale * rate / 44_100), 1))
    feedback = 0.72 + size * 0.2

    dry = SoundStudio.samples(clip.data)
    tail = trunc(rate * (0.3 + size * 1.2))
    padded = dry ++ List.duplicate(0, tail)

    wet =
      delays
      |> Enum.map(&comb(padded, &1, feedback))
      |> sum_lists()
      |> Enum.map(&(&1 / length(delays)))
      |> allpass(max(trunc(556 * rate / 44_100), 1), 0.5)

    data =
      padded
      |> Enum.zip(wet)
      |> Enum.reduce(<<>>, fn {d, w}, acc ->
        acc <> <<SoundStudio.clamp16(d * (1.0 - mix) + w * mix)::little-signed-16>>
      end)

    %{clip | data: data}
  end

  # y[n] = x[n] + f * y[n-d]
  defp comb(input, delay, feedback) do
    input
    |> Enum.reduce({[], :queue.from_list(List.duplicate(0.0, delay))}, fn x, {out, buf} ->
      {{:value, delayed}, rest} = :queue.out(buf)
      y = x + delayed * feedback
      {[y | out], :queue.in(y, rest)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # y[n] = -g*x[n] + x[n-d] + g*y[n-d]
  defp allpass(input, delay, g) do
    input
    |> Enum.reduce({[], :queue.from_list(List.duplicate(0.0, delay))}, fn x, {out, buf} ->
      {{:value, delayed}, rest} = :queue.out(buf)
      y = -g * x + delayed
      {[y | out], :queue.in(x + g * y, rest)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp sum_lists([first | rest]) do
    Enum.reduce(rest, first, fn list, acc -> Enum.zip_with(acc, list, &+/2) end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp defaults(params) do
    Map.new(params, fn {key, {_min, _max, default}} -> {key, default} end)
  end

  # Reads a parameter through the catalog's range, so a mix file that was
  # hand-edited — or written by an older version — cannot hand the DSP a value
  # its arithmetic was never checked against.
  defp param(%{type: type, params: params}, key) do
    with %{params: declared} <- entry(type),
         {_min, _max, default} = range <- Map.get(declared, key) do
      clamp(numeric(Map.get(params, key)) || default, range)
    else
      _other -> 1.0
    end
  end

  defp clamp(value, {min, max, _default}), do: value |> max(min) |> min(max)

  defp numeric(value) when is_number(value), do: value * 1.0

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp numeric(_value), do: nil

  defp at(table, i, count) when i >= 0 and i < count, do: elem(table, i)
  defp at(_table, _i, _count), do: 0

  defp chunk_frames(data, size) do
    for <<frame::binary-size(size) <- data>>, do: frame
  end
end
