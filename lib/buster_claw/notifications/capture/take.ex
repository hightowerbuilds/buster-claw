defmodule BusterClaw.Notifications.Capture.Take do
  @moduledoc """
  Turning captured PCM into a clip — the server half of the in-app recorder.

  Its caller is `BusterClaw.Voice.Reference`: Vox2B records the operator's
  reference voice through the `VoiceRecorder` hook, and `decode/2` is what makes
  those samples a clip and measures it.

  > It also stored and word-indexed takes for the cut-up corpus until 09-19,
  > when that engine was deleted (`CUTUP_DELETION_ROADMAP`). `store/3` and
  > everything that aliased `Cutup.*` went with it. What is left is the half that
  > was never the corpus's.

  The browser holds the microphone and this app holds the file format.
  `SoundStudio.write/2` has produced every WAV this app has ever written and is
  pinned by a byte-for-byte round-trip test, so the recorder ships raw `Float32`
  frames and lets tested Elixir make the file rather than growing a second WAV
  encoder in JavaScript that could disagree with the first.

  ## What arrives, and why it is floats

  An `AudioWorkletProcessor` hands back `Float32` samples in `[-1.0, 1.0]`,
  identically in WKWebView and in Chrome. `MediaRecorder` would have handed back
  MP4/AAC in one host and WebM/Opus in the other — both lossy, both needing a
  decoder, and **the two hosts would disagree** about what the same voice sounds
  like.

  So the wire format is a base64 `Float32` little-endian buffer plus the sample
  rate the device actually ran at. Nothing is resampled here: capture is kept at
  the device's native rate, because downsampling is lossy and irreversible and
  the master is the only way back.

  ## Clipping is detected, never repaired

  A float sample at or beyond ±1.0 means the converter ran out of range **before
  the signal reached the browser**. No amount of downstream gain recovers it —
  the waveform's top is already flat. `decode/2` therefore reports `clipped?` and
  the peak, so the caller can refuse the take at the door rather than letting it
  surface later as distortion in everything rendered from it.
  """

  alias BusterClaw.Notifications.SoundStudio

  # Int16 is the studio's working depth: `SoundStudio.peak/1` implements only
  # `bits: 16`, and every synthesized chime is 16-bit. Capturing at a depth
  # nothing downstream reads would be a private format.
  @bits 16
  @channels 1

  # Below this a "recording" is the microphone being absent rather than quiet.
  # `Commands.SoundCapture` already refuses digital silence from the `ffmpeg`
  # path for the TCC reason; the browser path can fail the same way when a
  # device is muted in System Settings, and the operator deserves the same
  # sentence rather than a file full of zeros.
  @silence_peak 0.0001

  # A sample rate the hardware could not plausibly have produced means the
  # caller's metadata is wrong, and a wrong rate is unrecoverable: it is not
  # stored in the samples, so the file plays at the wrong speed forever.
  @min_rate 8_000
  @max_rate 192_000

  @typedoc "A decoded take: the clip, and what measuring it found."
  @type t :: %{
          clip: SoundStudio.t(),
          peak: float(),
          clipped?: boolean(),
          duration_ms: float(),
          sample_rate: pos_integer()
        }

  @typedoc "Why a take was refused. Returned, never raised."
  @type error :: :invalid_pcm | :invalid_sample_rate | :empty_take | :silent_take

  @doc """
  Decode a base64 `Float32` little-endian buffer into a studio clip.

  Returns the clip alongside the three numbers the recorder must surface: the
  peak as a fraction of full scale, whether it clipped, and how long it is.

  Refuses an empty buffer (`:empty_take`) and one that is entirely, or nearly,
  digital silence (`:silent_take`) — see the moduledoc on why silence is a
  failure rather than a quiet success.
  """
  @spec decode(term(), term()) :: {:ok, t()} | {:error, error()}
  def decode(pcm, sample_rate) when is_binary(pcm) do
    with {:ok, rate} <- rate(sample_rate),
         {:ok, raw} <- base64(pcm),
         {:ok, floats} <- floats(raw) do
      measure(floats, rate)
    end
  end

  def decode(_pcm, _sample_rate), do: {:error, :invalid_pcm}

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  defp rate(value) when is_integer(value) and value >= @min_rate and value <= @max_rate,
    do: {:ok, value}

  defp rate(_value), do: {:error, :invalid_sample_rate}

  defp base64(pcm) do
    case Base.decode64(pcm) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :invalid_pcm}
    end
  end

  # A Float32 buffer is a whole number of 4-byte samples. A trailing partial one
  # means the transfer was truncated, and guessing at it would silently shorten
  # the take — `SoundStudio.parse/1` drops a partial frame for the same reason,
  # but here it indicates a broken upload rather than a quirk of a file.
  defp floats(raw) when byte_size(raw) == 0, do: {:error, :empty_take}

  defp floats(raw) when rem(byte_size(raw), 4) != 0, do: {:error, :invalid_pcm}

  defp floats(raw), do: {:ok, for(<<f::little-float-32 <- raw>>, do: f)}

  defp measure([], _rate), do: {:error, :empty_take}

  defp measure(floats, rate) do
    peak = floats |> Enum.reduce(0.0, &max(abs(&1), &2)) |> Float.round(6)

    if peak < @silence_peak do
      {:error, :silent_take}
    else
      {:ok, take(floats, rate, peak)}
    end
  end

  defp take(floats, rate, peak) do
    data = pcm16(floats)

    clip = %SoundStudio{
      sample_rate: rate,
      channels: @channels,
      bits: @bits,
      data: data
    }

    %{
      clip: clip,
      peak: peak,
      # At or beyond full scale the converter already ran out of range; see the
      # moduledoc. Measured on the FLOATS, before the int16 conversion below
      # clamps them, because clamping is what would hide it.
      clipped?: peak >= 1.0,
      duration_ms: SoundStudio.duration_ms(clip),
      sample_rate: rate
    }
  end

  # Float [-1.0, 1.0] to signed 16-bit little-endian.
  #
  # Scaling by 32_767 rather than 32_768 keeps +1.0 inside the positive rail
  # instead of wrapping to the negative one. Saturation is `SoundStudio`'s —
  # this module had its own copy until 08-16, which made three implementations
  # of "what is the loudest sample" for a value where disagreeing is audible.
  defp pcm16(floats) do
    for f <- floats, into: <<>> do
      <<SoundStudio.clamp16(f * 32_767)::little-signed-16>>
    end
  end
end
