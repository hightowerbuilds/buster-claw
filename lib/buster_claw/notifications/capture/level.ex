defmodule BusterClaw.Notifications.Capture.Level do
  @moduledoc """
  Reads and writes the **OS input volume** — the one capture control the web
  layer provably cannot reach.

  ## Why this is native at all

  Everything else about capture lives in the browser. This does not, because
  `getUserMedia` offers no control over the *hardware* input level: the
  constraint set can ask for a device, a rate and a channel count, but not for
  gain. The obvious substitute is a `GainNode` after capture, and it is not a
  substitute — it raises the level of what was recorded, but **it cannot undo
  clipping that already happened at the converter.** Once the analogue-to-digital
  stage squared a peak off, those samples are gone, and no amount of downstream
  gain brings them back. Setting the level *before* the converter is the only
  fix, and on macOS that means asking the OS.

  ## What it actually does — and what it does not

  Two facts the caller must pass on to the operator, verbatim if possible:

  1. **The scale is coarse: 0..100 integers, nothing finer.** This is
     AppleScript's volume scale, not a dB gain, and not the continuous control a
     mixer would give you.
  2. **It applies to the CURRENT DEFAULT INPUT DEVICE, not to a named device.**
     There is no device argument here and there cannot be one. If the operator
     changes their default input in System Settings, or plugs in an interface
     that grabs the default, a later `set/1` lands on the new device. Reading
     back with `get/0` reports that same current default.

  The roadmap (STUDIO_ROADMAP V.7, "Levels: an honest limitation") is blunt
  about the failure mode this module exists to avoid:

  > **Do not fake it.** A gain slider that silently only applies post-capture,
  > while the operator believes it is setting the mic, is worse than no slider.

  So a UI built on this must label it as the OS input volume for the current
  default device, and must not present `{:error, :no_input_device}` as `0`.
  A device with no controllable input level and a device turned all the way
  down look identical on a slider and mean opposite things — the first cannot
  be fixed here, the second is one drag from fixed.

  ## Errors

  macOS only; every failure is a tagged tuple and nothing raises.

    * `{:error, :no_osascript}` — not macOS, or `osascript` is missing or
      unrunnable.
    * `{:error, :no_input_device}` — AppleScript answered `missing value`:
      there is no input whose level this machine can control.
    * `{:error, :unparseable_level}` — the reply was neither `missing value`
      nor an integer in 0..100.
    * `{:error, {:osascript_failed, status}}` — non-zero exit.
    * `{:error, :invalid_volume}` — `set/1` was handed something that is not an
      integer in 0..100. Rejected *before* any command runs.
  """

  # Absolute path, and args are always a list, so nothing here ever reaches a
  # shell — a value can never be read as syntax.
  @osascript "/usr/bin/osascript"

  @get_script "input volume of (get volume settings)"

  @doc """
  Current OS input volume of the default input device, as an integer 0..100.

  Returns `{:ok, 0..100}`, or `{:error, reason}` — notably
  `{:error, :no_input_device}` when there is no controllable input, which is
  **not** the same as a level of `0`.

  `:runner` (arity-2, `command` and `args`, returning `{output, status}`) can be
  injected for tests.
  """
  def get(opts \\ []) do
    case run(["-e", @get_script], opts) do
      {:ok, output} -> parse_level(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sets the OS input volume of the **current default input device** to `volume`,
  an integer 0..100.

  Returns `:ok`, or `{:error, reason}`. Anything that is not an integer in
  0..100 — a float, a string of digits, `nil`, `-1`, `101` — is
  `{:error, :invalid_volume}` and never reaches the command.
  """
  def set(volume, opts \\ [])

  def set(volume, opts) when is_integer(volume) and volume >= 0 and volume <= 100 do
    # `volume` has passed the guard above, so this interpolation can only ever
    # be an integer 0..100 — and it is an element of an args list regardless.
    case run(["-e", "set volume input volume #{volume}"], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def set(_volume, _opts), do: {:error, :invalid_volume}

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  # `input volume of (get volume settings)` prints the bare field, e.g. "100\n".
  # The whole record — which we deliberately do not parse — looks like:
  #
  #     output volume:63, input volume:100, alert volume:0, output muted:false
  #
  # and the field is the literal `missing value` when no input level can be
  # controlled.
  defp parse_level(output) do
    case String.trim(to_string(output)) do
      "missing value" -> {:error, :no_input_device}
      trimmed -> parse_integer(trimmed)
    end
  end

  defp parse_integer(text) do
    case Integer.parse(text) do
      {level, ""} when level >= 0 and level <= 100 -> {:ok, level}
      _other -> {:error, :unparseable_level}
    end
  end

  # ---------------------------------------------------------------------------
  # Shelling out — the house pattern (see BusterClaw.SystemBrowser)
  # ---------------------------------------------------------------------------

  defp run(args, opts) do
    runner = Keyword.get(opts, :runner)

    cond do
      is_function(runner, 2) -> invoke(runner, args)
      not File.regular?(@osascript) -> {:error, :no_osascript}
      true -> invoke(&run_command/2, args)
    end
  end

  defp invoke(runner, args) do
    case runner.(@osascript, args) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:osascript_failed, status}}
    end
  rescue
    # System.cmd raises if the binary vanished between the check and the call,
    # or cannot be executed at all.
    _error -> {:error, :no_osascript}
  end

  defp run_command(command, args), do: System.cmd(command, args, stderr_to_stdout: true)
end
