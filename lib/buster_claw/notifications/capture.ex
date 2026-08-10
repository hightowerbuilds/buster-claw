defmodule BusterClaw.Notifications.Capture do
  @moduledoc """
  Agent-addressable audio capture (STUDIO_ROADMAP V.9) — the BEAM spawning
  `ffmpeg -f avfoundation` to land a recording in the Studio's sources.

  This is the *only* capture route that works today with zero packaging
  changes, and the only one an assistant can reach without a human clicking
  anything: *"record thirty seconds of room tone"* with nobody at the keyboard.
  It is a **convenience with a caveat**, not the operator's recording path —
  V.3 reserves that for the front end, for the reason below.

  ## The process boundary, which is the whole reason this module is careful

  **Entitlements and TCC consent do not cross process boundaries.** The process
  that opens the microphone is the process that needs the grant. Here that
  process is `ffmpeg`, spawned by `beam.smp`, which is itself spawned out of
  `Contents/Resources` — a process with no `Info.plist` and no
  `NSMicrophoneUsageDescription`, so macOS attributes consent to whatever it
  decides is *responsible* up the chain. The prompt may go to the wrong app, or
  never appear at all.

  And when it does not appear, **`ffmpeg` does not fail.** It opens the device,
  reads frames of zeroes, writes a well-formed WAV, and exits 0. Measured on
  the author's Mac 08-09: 1.000 s captured, 21_109 samples, **every one of them
  exactly zero, exit status 0, nothing on stderr.** That is the worst failure
  mode available — a success return that is really a file full of nothing.

  So `record/1` **verifies the audio before reporting success** and, when the
  capture is silent, returns an error that names the cause and the fix in words
  an operator can act on. A success return from this module means audio was
  actually captured.

  ## What it does not do

  No live metering (`ffmpeg` is a black box mid-capture), no device-change
  handling, and **no chime routing.** A recording lands in `sounds/studio/` as
  a *source*; `sound_apply` remains the separate, trust-gated act of making
  something a notification sound. Nothing here touches it.
  """

  require Logger

  alias BusterClaw.Notifications.SoundStudio

  # Homebrew puts ffmpeg in a different place on Intel and Apple Silicon, and
  # unlike `afconvert`/`afinfo` (macOS system binaries, always at a fixed path)
  # ffmpeg is something the operator installed. So: known locations first, then
  # PATH, and a missing binary is `{:error, :no_recorder}` — never a raise.
  @candidates ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]

  # Duration ceiling, in seconds. Five minutes, matching `SoundStudio`'s
  # mixdown ceiling: audio longer than the arranger can ever render is audio
  # this module has no business producing. It is also ~13 MB at the internal
  # format, which is a sane thing for an agent to be able to ask for without a
  # confirmation step.
  @max_seconds 300

  # Slack on top of the requested duration before the BEAM stops waiting.
  # avfoundation takes a beat to open a device, and `-t` is measured from the
  # first frame, not from process start.
  @startup_grace_ms 10_000

  # The silence floor, as a fraction of full scale. ~-70 dBFS, about ten int16
  # steps.
  #
  # **This is deliberately a near-zero test, not an exact-zero test, and the two
  # are different claims.** TCC-denied capture on this machine measures exactly
  # 0.0, so any threshold at all catches it. The reason not to stop at `== 0.0`
  # is the neighbouring fault: a device that is *open but delivering nothing* —
  # muted input, a fader at zero, an interface that dropped its clock — can
  # dither out a handful of least-significant bits, and reporting that as a
  # successful recording is the same bug wearing a smaller number.
  #
  # It is set near the bottom of the scale rather than at a "quiet room" level
  # on purpose. A consented microphone's true noise floor cannot be measured
  # here — the absence of consent is the fault this module exists for — so the
  # threshold makes no assumption about it. -70 dBFS is roughly 300x quieter
  # than a whisper at conversational distance; a real capture clears it by
  # orders of magnitude, and anything that does not clear it is not audio
  # anyone can use.
  @silence_floor 3.0e-4

  @typedoc "A successful capture."
  @type result :: %{
          name: String.t(),
          path: String.t(),
          duration_ms: non_neg_integer(),
          peak: float(),
          clipped: boolean(),
          sample_rate: pos_integer(),
          channels: pos_integer(),
          bits: pos_integer(),
          device: String.t()
        }

  @doc "The longest capture this module will run, in seconds."
  def max_seconds, do: @max_seconds

  @doc "The peak below which a capture is treated as silence. See the moduledoc."
  def silence_floor, do: @silence_floor

  @doc """
  Absolute path to `ffmpeg`, or `nil`.

  Checked at call time rather than at compile time: the operator can install
  ffmpeg after the app boots, and a build that baked in "absent" would keep
  saying so forever.
  """
  def recorder_path do
    Enum.find(@candidates, &File.regular?/1) || System.find_executable("ffmpeg")
  end

  @doc "True when a recorder binary is available. Asked cheaply, like `SoundStudio.decoder_available?/0`."
  def recorder_available?, do: is_binary(recorder_path())

  @doc """
  True when a clip carries no usable audio — its peak sits at or below the
  silence floor.

  Public because it is the load-bearing check in this module and deserves to be
  exercised on synthesized buffers rather than only through a microphone that
  may not be granted.
  """
  def silent?(%SoundStudio{} = clip), do: SoundStudio.peak(clip) <= @silence_floor

  @doc """
  Record from an input device into the Studio's sources.

  ## Options

    * `:seconds` — **required.** How long to record, `0 < seconds <= #{@max_seconds}`.
    * `:name` — optional output name. Defaults to `recording-<utc timestamp>.wav`.
      The extension is forced to `.wav` by `SoundStudio.save/2`.
    * `:device` — optional avfoundation audio device, by index (`0`) or by name
      (`"MacBook Pro Microphone"`). Defaults to the system default input.
    * `:runner` — test seam. A 2-arity function with `System.cmd/2`'s shape,
      `(binary, args) -> {output, exit_status}`. Supplying it skips the
      binary-presence check, which is how the silence path can be tested on a
      machine with no microphone consent — i.e. on any machine.
    * `:grace_ms` — test seam. How long past `:seconds` the BEAM waits before
      giving up on a wedged device. Defaults to #{@startup_grace_ms}.

  ## Returns

  `{:ok, result}` where `result` carries `:name`, `:path`, `:duration_ms`,
  `:peak`, `:clipped` and the real header fields read back off the file.

  `{:error, reason}` for everything else, and never a raise:

    * `:duration_required`, `:invalid_duration`, `:duration_too_long`
    * `:invalid_device`, `:invalid_runner`, `:invalid_options`
    * `:no_recorder` — ffmpeg is not installed
    * `{:capture_failed, status}` — ffmpeg exited non-zero (bad device, busy
      device). Its stderr goes to the log.
    * `:timeout` — the run outran its own `-t` plus grace
    * `:unreadable_capture` — exit 0 but nothing parseable on disk
    * `{:unexpected_format, {rate, channels, bits}}` — ffmpeg wrote something
      that is not the internal format
    * `{:silent_capture, message}` — **the TCC case.** `message` names System
      Settings → Privacy & Security → Microphone.
  """
  def record(opts) when is_list(opts) do
    with {:ok, seconds} <- duration(Keyword.get(opts, :seconds)),
         {:ok, device} <- device_spec(Keyword.get(opts, :device)),
         {:ok, runner, bin} <- runner(Keyword.get(opts, :runner)) do
      grace = grace_ms(Keyword.get(opts, :grace_ms, @startup_grace_ms))
      capture(bin, runner, {seconds, grace}, device, Keyword.get(opts, :name))
    end
  end

  def record(_opts), do: {:error, :invalid_options}

  defp duration(nil), do: {:error, :duration_required}

  defp duration(seconds) when is_number(seconds) do
    cond do
      seconds <= 0 -> {:error, :invalid_duration}
      seconds > @max_seconds -> {:error, :duration_too_long}
      true -> {:ok, seconds}
    end
  end

  # `:infinity`, "30", nil-in-a-tuple — an unbounded record is a hung BEAM
  # process, so anything that is not a plain number in range is refused before
  # a subprocess exists.
  defp duration(_other), do: {:error, :invalid_duration}

  defp grace_ms(ms) when is_integer(ms) and ms >= 0, do: ms
  defp grace_ms(_other), do: @startup_grace_ms

  defp runner(nil) do
    case recorder_path() do
      nil -> {:error, :no_recorder}
      bin -> {:ok, fn exe, args -> System.cmd(exe, args, stderr_to_stdout: true) end, bin}
    end
  end

  defp runner(fun) when is_function(fun, 2), do: {:ok, fun, "ffmpeg"}
  defp runner(_other), do: {:error, :invalid_runner}

  defp capture(bin, runner, {seconds, grace}, device, name) do
    tmp = Path.join(System.tmp_dir!(), "bccapture-#{:erlang.unique_integer([:positive])}.wav")

    try do
      case run(bin, runner, args(device, seconds, tmp), {seconds, grace}) do
        :ok -> finish(tmp, device, name)
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(tmp)
    end
  end

  # avfoundation's input spec is `video:audio`; an empty video half is how you
  # ask for audio only. `"default"` is the keyword for the system default input
  # — verified against ffmpeg 8.1, as is the by-name form (`":Some Mic"`, which
  # fails without the leading colon).
  defp device_spec(nil), do: {:ok, ":default"}
  defp device_spec(device) when is_integer(device) and device >= 0, do: {:ok, ":#{device}"}

  defp device_spec(device) when is_binary(device) do
    if String.trim(device) == "", do: {:error, :invalid_device}, else: {:ok, ":#{device}"}
  end

  defp device_spec(_other), do: {:error, :invalid_device}

  # Capture at whatever the device gives us (48 kHz f32 here) and let
  # swresample do 48000 -> 22050. That ratio is ~2.1769, not an integer, so
  # naive decimation would alias badly; swr applies the low-pass the conversion
  # requires. `-nostdin` matters: this runs under a port, and an ffmpeg that
  # reads stdin would fight the BEAM for it.
  defp args(device, seconds, out) do
    {rate, channels, _bits} = SoundStudio.internal_format()

    [
      "-hide_banner",
      "-nostdin",
      "-loglevel",
      "error",
      "-f",
      "avfoundation",
      "-i",
      device,
      "-t",
      to_string(seconds),
      "-ac",
      to_string(channels),
      "-ar",
      to_string(rate),
      "-c:a",
      "pcm_s16le",
      "-y",
      out
    ]
  end

  # Two bounds, because they cover different failures. ffmpeg's own `-t` ends a
  # healthy capture; the Task deadline stops a *wedged* one from hanging the
  # caller — a device that never delivers a first frame never reaches `-t`.
  # Args are a list, so nothing here touches a shell.
  defp run(bin, runner, args, {seconds, grace}) do
    task = Task.async(fn -> spawn_recorder(bin, runner, args) end)
    deadline = trunc(seconds * 1000) + grace

    case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {:recorder_failed, message}} ->
        Logger.warning("Capture.record: recorder failed: #{message}")
        {:error, :no_recorder}

      {:ok, {output, status}} ->
        detail = output |> to_string() |> String.trim()
        Logger.warning("Capture.record: ffmpeg exited #{status}: #{detail}")
        {:error, {:capture_failed, status}}

      _ ->
        {:error, :timeout}
    end
  end

  # The rescue belongs **inside** the task, not around it. `System.cmd/3` raises
  # when the binary vanished between the check and the call, and a raise in a
  # linked Task takes the *caller* down — an outer `rescue` never sees it. Found
  # by the missing-binary test, which failed with an EXIT before this moved.
  defp spawn_recorder(bin, runner, args) do
    runner.(bin, args)
  rescue
    error -> {:recorder_failed, Exception.message(error)}
  end

  defp finish(tmp, device, name) do
    with {:ok, clip} <- read_capture(tmp),
         :ok <- check_format(clip),
         :ok <- check_signal(clip) do
      save(clip, device, name)
    end
  end

  defp read_capture(tmp) do
    case SoundStudio.read(tmp) do
      {:ok, clip} -> {:ok, clip}
      {:error, _reason} -> {:error, :unreadable_capture}
    end
  end

  # Read the header back rather than trusting the flags we passed. Verified
  # 08-09 against ffmpeg 8.1: PCM (format 1), 1 channel, 22050 Hz, 16-bit —
  # with a `LIST`/`ISFT` chunk sitting between `fmt ` and `data`, which is
  # exactly why `SoundStudio.parse/1` walks the chunk list instead of seeking
  # to byte 44.
  defp check_format(clip) do
    if SoundStudio.internal?(clip) do
      :ok
    else
      {:error, {:unexpected_format, {clip.sample_rate, clip.channels, clip.bits}}}
    end
  end

  defp check_signal(clip) do
    if silent?(clip), do: {:error, {:silent_capture, silence_message(clip)}}, else: :ok
  end

  defp silence_message(clip) do
    peak = SoundStudio.peak(clip)

    """
    The recording finished without an error but contains no audio (peak #{Float.round(peak, 6)}).

    On macOS this almost always means microphone access was never granted. \
    Consent belongs to the process that opens the device, and that process here \
    is ffmpeg launched by Buster Claw — so the permission prompt may have gone \
    to the app that started Buster Claw, or never appeared at all.

    Fix it by hand: System Settings -> Privacy & Security -> Microphone, and \
    switch on the app you launched Buster Claw from (Terminal, or Buster Claw \
    itself). macOS will not ask again on its own once the decision is recorded.

    Also worth checking, if access is already on: the input volume is not at \
    zero, and the right device is selected in Sound settings.
    """
  end

  # `save/2` renders through `SoundStudio.render/1`, which canonicalizes the
  # file to the studio's minimal header — ffmpeg's ISFT metadata chunk does not
  # survive, and should not.
  #
  # It also de-duplicates the name (`room-tone.wav`, `room-tone-2.wav`) rather
  # than overwriting. **De-duplication, not an error, and the audio is the
  # reason:** by the time a collision is discovered the recording has already
  # happened and cannot be re-taken, so refusing would throw away the one thing
  # here that is unrepeatable.
  defp save(clip, device, name) do
    case SoundStudio.save(clip, name || default_name()) do
      {:ok, stored} -> {:ok, describe(clip, stored, device)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp describe(clip, stored, device) do
    peak = SoundStudio.peak(clip)

    %{
      name: stored,
      path: Path.join(SoundStudio.dir(), stored),
      duration_ms: round(SoundStudio.duration_ms(clip)),
      peak: peak,
      clipped: peak >= 1.0,
      sample_rate: clip.sample_rate,
      channels: clip.channels,
      bits: clip.bits,
      device: device
    }
  end

  defp default_name do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    "recording-#{stamp}.wav"
  end
end
