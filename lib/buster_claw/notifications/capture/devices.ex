defmodule BusterClaw.Notifications.Capture.Devices do
  @moduledoc """
  Audio input devices available for recording — the read half of the Studio's
  recorder, and the data behind a future `sound_devices` verb.

  ## The rate here is a *claim*, not a measurement

  `sample_rate_hz` is the rate CoreAudio advertises for the device. It is **not**
  the rate an open capture stream will actually run at, and the two disagree in
  exactly the case that matters most (see Bluetooth, below). STUDIO_ROADMAP V.6
  requires any recording UI to display the *live* stream's rate —
  `AudioContext.sampleRate` / `track.getSettings()` — and to warn below 32 kHz.
  This module cannot see a live stream, so nothing it returns may be presented as
  the truth about a recording in progress. Use it to *choose* a device; read the
  stream to *describe* one.

  ## Why `transport` exists at all

  Bluetooth audio has two profiles: A2DP (output, high quality) and HFP/HSP
  (bidirectional, much worse). **Opening a Bluetooth headset as an input drags the
  whole device out of A2DP into HFP** — 8 kHz narrowband classic, 16 kHz with
  wideband mSBC. The corpus this feature exists to improve is already 8 kHz
  telephony audio, so a donor recording made over AirPods would hand the project a
  *second* 8 kHz corpus and gain nothing. That is why transport is labelled here,
  in the enumeration, *before* a device can be selected — a warning after the fact
  is a warning too late.

  ## Where the data comes from

  `system_profiler SPAudioDataType -json`, and not `ffmpeg -f avfoundation
  -list_devices true`. The ffmpeg route was evaluated and rejected: it writes its
  device list to **stderr**, exits non-zero by design, interleaves video devices
  with audio ones, and reports **only an index and a name** — no transport, no
  channel count, no sample rate, which is to say none of the three fields this
  module exists to provide. `system_profiler` is a first-party binary at a fixed
  path emitting structured JSON with all of them.

  A device is an *input* if CoreAudio gives it an input channel count or flags it
  as the default input; pure outputs (speakers, a DisplayPort monitor) are dropped.

  ## Transport mapping

  The reporter's own table of transport strings — read out of
  `SPAudioReporter.spreporter`, not guessed — is exactly twelve values:

      builtin  usb  bluetooth  virtual  displayport  hdmi
      airplay  avb  firewire   thunderbolt  pci  unknown

  The first four map to their obvious atoms; everything else maps to `:unknown`,
  because the caller's contract has no bucket for them and inventing one silently
  is worse than admitting ignorance. Note there is **one** Bluetooth string in
  that table: a Bluetooth-LE transport, which CoreAudio distinguishes internally,
  may surface here as `:unknown` rather than `:bluetooth`. A caller that must not
  record over Bluetooth should treat `:unknown` as unproven, not as safe.

  Errors are always `{:error, reason}` — a missing binary, a timeout, a non-zero
  exit, or a payload that does not parse. There is no partial success: if any
  input device in the payload cannot be read, the whole read fails rather than
  returning a list with a hole in it.
  """

  # A first-party macOS binary at a fixed path — the same rule `SoundStudio`
  # follows for `afconvert`/`afinfo`: name the absolute path, never search $PATH.
  @profiler "/usr/sbin/system_profiler"

  @default_timeout_ms 10_000

  @transports %{
    "coreaudio_device_type_builtin" => :builtin,
    "coreaudio_device_type_usb" => :usb,
    "coreaudio_device_type_bluetooth" => :bluetooth,
    "coreaudio_device_type_virtual" => :virtual
  }

  @type transport :: :builtin | :usb | :bluetooth | :virtual | :unknown

  @type device :: %{
          name: String.t(),
          transport: transport(),
          channels: pos_integer() | nil,
          sample_rate_hz: pos_integer() | nil,
          default?: boolean()
        }

  @doc """
  Audio input devices available for recording.

  Options:

    * `:timeout_ms` — how long `system_profiler` gets before it is killed
      (default #{@default_timeout_ms}).
    * `:reader` — a zero-arity function returning `{:ok, json_binary}` or
      `{:error, reason}`, in place of running the binary. This exists so the
      parser can be tested against captured real output; hardware cannot be
      asserted on in CI.

  Returns `{:ok, [device]}` — possibly an empty list, which is a legitimate
  answer on a Mac with no inputs — or `{:error, reason}`.
  """
  @spec list(keyword()) :: {:ok, [device()]} | {:error, term()}
  def list(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    reader = Keyword.get(opts, :reader, fn -> read_profile(timeout_ms) end)

    case reader.() do
      {:ok, payload} -> parse(payload)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unreadable}
    end
  end

  @doc """
  The system default input device.

  `{:error, :no_input_device}` covers both "this Mac has no inputs" and "no input
  is flagged as the system default" — on macOS these coincide, because CoreAudio
  promotes an input to default whenever any exists. Read errors from `list/1`
  (`:no_profiler`, `:timeout`, `:unparseable`, …) pass through unchanged rather
  than being flattened into `:no_input_device`, so a broken toolchain never
  masquerades as absent hardware.
  """
  @spec default(keyword()) :: {:ok, device()} | {:error, term()}
  def default(opts \\ []) do
    with {:ok, devices} <- list(opts) do
      case Enum.find(devices, & &1.default?) do
        nil -> {:error, :no_input_device}
        device -> {:ok, device}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Reading — bounded, and never raising
  # ---------------------------------------------------------------------------

  defp read_profile(timeout_ms) do
    if File.regular?(@profiler) do
      run_profiler(timeout_ms)
    else
      {:error, :no_profiler}
    end
  end

  defp run_profiler(timeout_ms) do
    task = Task.async(&profiler_output/0)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} -> {:ok, output}
      {:ok, {:ok, {_output, status}}} -> {:error, {:exit_status, status}}
      {:ok, {:error, :unavailable}} -> {:error, :no_profiler}
      _other -> {:error, :timeout}
    end
  end

  # `System.cmd/3` raises if the binary vanished between the `File.regular?`
  # check and this call, or cannot be executed at all. `Task.async/1` *links*, so
  # a raise inside the task would take this process down with it before
  # `Task.yield/2` could report anything — the rescue has to live inside the
  # task, not around it.
  #
  # Two deliberate details: the args are a list, so this never reaches a shell;
  # and `stderr_to_stdout` stays FALSE, unlike the rest of this codebase's
  # `System.cmd` calls, because the stdout of this command has to be valid JSON
  # and a single stray warning line would turn a working read into
  # `:unparseable`.
  defp profiler_output do
    {:ok, System.cmd(@profiler, ["SPAudioDataType", "-json"], stderr_to_stdout: false)}
  rescue
    _error -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  defp parse(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"SPAudioDataType" => sections}} when is_list(sections) ->
        sections |> Enum.flat_map(&items/1) |> Enum.filter(&input?/1) |> devices()

      {:ok, _other} ->
        {:error, :unexpected_payload}

      {:error, _reason} ->
        {:error, :unparseable}
    end
  end

  defp parse(_payload), do: {:error, :unparseable}

  # `_items` nests: the current reporter puts every device one level down under a
  # `coreaudio_device` group, and older macOS releases added another level. Walk
  # to the leaves instead of indexing a fixed depth, so neither shape is a
  # silently empty list.
  defp items(%{"_items" => nested}) when is_list(nested), do: Enum.flat_map(nested, &items/1)
  defp items(%{} = leaf), do: [leaf]
  defp items(_other), do: []

  defp input?(%{"coreaudio_device_input" => _channels}), do: true
  defp input?(%{"coreaudio_default_audio_input_device" => _flag}), do: true
  defp input?(_item), do: false

  defp devices(items) do
    case Enum.reduce_while(items, [], &collect/2) do
      {:error, reason} -> {:error, reason}
      collected -> {:ok, Enum.reverse(collected)}
    end
  end

  defp collect(item, collected) do
    case device(item) do
      {:ok, device} -> {:cont, [device | collected]}
      :error -> {:halt, {:error, :unexpected_payload}}
    end
  end

  # `_name` is the device name, and `coreaudio_input_source` is NOT — on this
  # machine a Continuity Camera microphone reports the literal placeholder
  # `"spaudio_default"` in that field while carrying its real name in `_name`.
  #
  # A nameless input is unusable in a picker and signals a payload we do not
  # understand, so it fails the whole read rather than appearing as "Unknown".
  defp device(item) do
    case item["_name"] do
      name when is_binary(name) and name != "" ->
        {:ok,
         %{
           name: name,
           transport: transport(item),
           channels: positive_integer(item["coreaudio_device_input"]),
           sample_rate_hz: positive_integer(item["coreaudio_device_srate"]),
           # The *system default* flag is a different key and often a different
           # device — here it lands on a DisplayPort monitor, an output. Only the
           # input flag may decide `default?`.
           default?: item["coreaudio_default_audio_input_device"] == "spaudio_yes"
         }}

      _other ->
        :error
    end
  end

  defp transport(%{"coreaudio_device_transport" => value}) when is_binary(value),
    do: Map.get(@transports, value, :unknown)

  defp transport(_item), do: :unknown

  # An absent, zero, or non-numeric count is reported as `nil` rather than
  # guessed at: "we do not know the channel count" and "this device has one
  # channel" lead to different recordings.
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(value) when is_float(value) and value >= 1.0, do: trunc(value)
  defp positive_integer(_value), do: nil
end
