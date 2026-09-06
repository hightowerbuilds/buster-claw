defmodule BusterClaw.Voice.Calibration do
  @moduledoc """
  What a render costs **on this machine**, learned from the renders it has done.

  ## Why this exists

  Until 09-06 the app quoted nothing and capped everything at ten minutes flat.
  On the operator's Intel i9 that ceiling was *below* the real cost of an
  ordinary clone, so a five-word line was killed at the limit with the work
  discarded — every time. The feature had never once succeeded there, and the
  only thing on screen was a stopwatch counting toward a number nobody had
  measured.

  A single constant cannot be right for both that laptop and an M4, so this
  stores what was actually observed and uses it for both jobs: **quoting the
  wait before the button is pressed, and setting the deadline that ends it.**

  ## Where a render's time actually goes

  Measured on the operator's i9 on 09-06, rendering `"Take me to the river!"`
  against a 6-second reference, twice, watching the engine's own progress bars:

  | Phase | 10 steps, denoiser on | 4 steps, denoiser off |
  |---|---|---|
  | model load | ~60 s | ~60 s |
  | warm-up | **10** iters at 26.7 s | **10** iters at 20.7 s |
  | generation | 24.5 s per step | 9.6 s per step |
  | **total** | **585 s** | **380 s** |

  Three things in that table are worth more than the numbers.

  **The fixed half is paid per invocation.** The app shells out to the `voxcpm`
  CLI once per line, so the model load and the whole warm-up are re-paid for
  every single clip. The engine's `batch` subcommand exists precisely to pay
  them once for many lines, which is why a whole chime set was never as
  expensive as its line count suggested.

  **The variable half scales with the text, not the audio.** The generation bar
  is one step per output chunk, so a longer sentence costs proportionally more.
  The first version of this module had no term for text length at all and would
  have quoted a paragraph the same as a word.

  **`--inference-timesteps` scales generation and NOT the warm-up.** This one
  was assumed wrong and then measured: the first version of this file claimed
  the step count halved "both halves of the bill". It does not. Asking for 4
  steps instead of 10 took generation from 24.5 s to 9.6 s per step — dead
  linear — while the warm-up ran its **ten** iterations either way. So the fixed
  cost is a floor no setting reaches, and the honest promise is smaller than the
  one first written here.

      total ≈ fixed + characters × (base + slope × reference_seconds) × steps/10

  The reference sits inside the per-character term rather than beside it because
  cloning attends over the reference on every step: a longer clip makes each
  step slower, it is not a one-off admission fee.

  ## The constants are a seed, not a law

  They come from the measurements above — one machine, two runs, one of which
  was killed before it finished. That is thin, and it is why `record/3` rescales
  them from what really happens. A faster machine stops using the operator's
  numbers after its first successful render.

  ## Why it rescales rather than fits

  With a handful of samples a least-squares fit produces confident nonsense:
  negative intercepts, slopes that invert. So the *shape* above is held fixed
  and only its magnitude moves, by a smoothed ratio of observed to predicted.
  That cannot invert, cannot go negative, and converges on a machine that is
  uniformly faster or slower — which is the case that actually occurs.

  A quote from this is an estimate, and the copy that shows it must say so.
  """

  alias BusterClaw.Settings
  alias BusterClaw.Voice.Config

  require Logger

  @key "voice_calibration"

  # Seeded from the 09-06 runs, all of `"Take me to the river!"` (21 characters)
  # on the operator's i9:
  #
  #   13.3 s ref, 10 steps, denoiser on   -> killed at 628 s, never finished
  #    6.0 s ref, 10 steps, denoiser on   -> 585 s, exit 0
  #    6.0 s ref,  4 steps, denoiser off  -> 380 s, exit 0
  #
  # `fixed_s` is the 60 s load plus a 207 s warm-up — the warm-up as it runs
  # NOW, with the denoiser off, which is the only way this app renders since
  # 09-06. (It was 266 s while a speech-enhancement model nothing calls was
  # being loaded.) The warm-up does not scale with the step count; see the
  # moduledoc.
  #
  # 12.3 s per character at a 6-second reference and 10 steps comes from run
  # two's 259 s of generation over 21 characters, and run three confirms the
  # scaling: predicted 370 s against 380 s measured, 2.4% low. Splitting that
  # per-character figure between `base` and `slope` is still the weakest part —
  # the failed 13.3 s run only proves its per-character cost exceeds 14.4 s, and
  # these constants put it at 17.6. `record/4` corrects all of it from real
  # renders; a seed only has to start somewhere honest.
  @seed %{fixed_s: 267.0, base_s: 8.0, slope_s: 0.72, samples: 0}

  # How fast the constants chase reality. One odd render — a thermally throttled
  # laptop, a machine that was also compiling — should move the quote, not
  # redefine it.
  @smoothing 0.4

  # The engine's own default when `--inference-timesteps` is absent.
  @default_steps 10

  @doc "The current constants, seeded when nothing has been recorded yet."
  @spec get() :: map()
  def get do
    case Settings.get(@key) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"fixed_s" => f, "base_s" => b, "slope_s" => s} = m} ->
            %{fixed_s: f, base_s: b, slope_s: s, samples: m["samples"] || 0}

          _ ->
            @seed
        end

      _ ->
        @seed
    end
  rescue
    _ -> @seed
  catch
    :exit, _ -> @seed
  end

  @doc """
  Estimated seconds to render `text`.

  `reference_seconds` is `0.0` for a design render — no reference clip — which
  is the cheap path, and the reason a chime set rendered before the operator
  recorded his voice cost a fraction of one recorded afterwards.

  Step count scales the GENERATION only. The warm-up runs its ten iterations
  whatever is asked for, so halving the steps does not halve the wait — it
  halves the part of the wait that is not a floor. Measured: 585 s -> 380 s for
  10 steps -> 4, on a job whose fixed cost is 267 s of that.
  """
  @spec estimate_seconds(String.t() | non_neg_integer(), number(), pos_integer() | nil) :: float()
  def estimate_seconds(text, reference_seconds \\ 0.0, steps \\ nil)

  def estimate_seconds(text, reference_seconds, steps) when is_binary(text),
    do: estimate_seconds(String.length(text), reference_seconds, steps)

  def estimate_seconds(chars, reference_seconds, steps) when is_integer(chars) do
    c = get()
    ref = reference_seconds || 0.0
    scale = (steps || @default_steps) / @default_steps

    # `scale` multiplies the generation term ONLY. It used to multiply the whole
    # expression, which quoted a 4-step render at 40% of a 10-step one when the
    # measured answer is 65% — the fixed half is a floor no setting reaches.
    c.fixed_s + chars * (c.base_s + c.slope_s * ref) * scale
  end

  @doc """
  The deadline for a render: the estimate with room for a bad day.

  Doubling is not superstition, it is the gap between a quote and a promise. A
  render killed at its estimate would throw away finished work the first time
  the machine was busy — the exact failure this module was written after. The
  floor keeps an optimistic calibration from setting a deadline shorter than a
  model load, and the ceiling keeps a pathological one from wedging the single
  render queue for an hour.
  """
  @spec deadline_ms(String.t() | non_neg_integer(), number(), pos_integer() | nil) ::
          pos_integer()
  def deadline_ms(text, reference_seconds \\ 0.0, steps \\ nil) do
    Application.get_env(:buster_claw, :voice_render_timeout_ms) ||
      text
      |> estimate_seconds(reference_seconds, steps)
      |> Kernel.*(2.0)
      |> then(&max(&1, 300.0))
      |> then(&min(&1, 5_400.0))
      |> Kernel.*(1000)
      |> round()
  end

  @doc """
  Record what a finished render actually cost, and rescale the constants.

  Only successful renders are recorded. A timeout says the job was longer than
  the deadline and nothing more precise; feeding it in would teach the model the
  deadline rather than the cost.
  """
  @spec record(String.t() | non_neg_integer(), number(), pos_integer() | nil, number()) :: :ok
  def record(text, reference_seconds, steps, elapsed_s)
      when is_number(elapsed_s) and elapsed_s > 0 do
    c = get()
    predicted = estimate_seconds(text, reference_seconds, steps)

    if predicted > 0 do
      ratio = 1.0 + @smoothing * (elapsed_s / predicted - 1.0)

      store(%{
        fixed_s: c.fixed_s * ratio,
        base_s: c.base_s * ratio,
        slope_s: c.slope_s * ratio,
        samples: c.samples + 1
      })
    end

    :ok
  rescue
    error ->
      Logger.warning("voice calibration not recorded: #{Exception.message(error)}")
      :ok
  catch
    # A Settings write with no database behind it — a test process that owns no
    # sandbox connection, a boot that has not finished — must lose the sample
    # and nothing else. A quote is a convenience; a render is the work.
    :exit, _ -> :ok
  end

  def record(_text, _reference_seconds, _steps, _elapsed_s), do: :ok

  @doc """
  `record/4` somewhere else, so a render never waits on a database write.

  Unmonitored and unlinked on purpose, which is the opposite of the rule the
  render job follows: a lost sample costs a slightly worse quote next time,
  where a lost render costs minutes of the operator's afternoon. The two
  failures are not comparable and neither are their guarantees.
  """
  @spec record_async(String.t() | non_neg_integer(), number(), pos_integer() | nil, number()) ::
          :ok
  def record_async(text, reference_seconds, steps, elapsed_s) do
    spawn(fn -> record(text, reference_seconds, steps, elapsed_s) end)
    :ok
  end

  @doc """
  A human phrase for the wait, or nothing worth saying.

  Deliberately coarse. The estimate is not accurate to the second, and a figure
  that looks precise invites being read as a promise.
  """
  @spec phrase(String.t() | non_neg_integer(), number(), pos_integer() | nil) :: String.t()
  def phrase(text, reference_seconds \\ 0.0, steps \\ nil) do
    minutes = estimate_seconds(text, reference_seconds, steps) / 60.0

    cond do
      minutes < 1.0 -> "under a minute"
      minutes < 2.5 -> "a minute or two"
      minutes < 60.0 -> "about #{round(minutes)} minutes"
      true -> "over an hour"
    end
  end

  @doc "Whether a quote is long enough that the operator deserves it up front."
  @spec slow?(String.t() | non_neg_integer(), number(), pos_integer() | nil) :: boolean()
  def slow?(text, reference_seconds \\ 0.0, steps \\ nil),
    do: estimate_seconds(text, reference_seconds, steps) > 90.0

  @doc "Steps the engine will actually use, given the operator's settings."
  @spec steps() :: pos_integer()
  def steps, do: Config.get().inference_timesteps || @default_steps

  @doc "The engine's default step count, for copy that needs to name it."
  def default_steps, do: @default_steps

  defp store(map) do
    Settings.put(@key, Jason.encode!(map))
    :ok
  end
end
