defmodule BusterClaw.Commands.SoundCapture do
  @moduledoc """
  Command surface for audio capture and for the corpus's coverage report —
  `STUDIO_ROADMAP` Part V.

  Separate from `BusterClaw.Commands.Sound` on purpose. That module is the
  cutting surface: it opens sources, searches indexes, splices and routes. These
  five verbs point the other way — at the microphone, at the OS mixer, and at the
  question *"what is the corpus missing?"* Keeping them apart also stops the
  Sound module, already the largest file in `lib/`, from absorbing a second
  concern.

  ## What each one is for

  | Verb | Half | |
  |---|---|---|
  | `sound_gaps` | read | Vocabulary coverage. **The report a donor passage is written against.** |
  | `sound_devices` | read | What can be recorded with, and at what rate. |
  | `sound_input_level` | read | OS input volume, 0-100. |
  | `sound_input_level_set` | mutate | Set it. Reversible, changes no file. |
  | `sound_record` | mutate, **gated** | Capture from an input device into `sounds/studio/`. |

  ## Why `sound_record` is gated, and the others are not

  `sound_record` turns on the microphone. `PolicyEngine`'s baseline is precise
  about what that costs: `:restricted` earns a confirmation for an `:agent` or
  `:mcp` caller, but **an `:agent_untrusted` caller is stopped only by
  `gated: true`.** So a `:restricted`-but-ungated recording verb would be
  reachable, without confirmation, by an autonomous run processing
  untrusted-origin content — email it did not choose to read. That is a
  room-recording capability driven by an untrusted input, and no phrasing of the
  convenience argument survives it.

  Gating costs the feature almost nothing, which is what makes the trade easy: a
  **trusted** caller — the operator at the CLI, or a chat session they are sitting
  in front of — still records directly. Only the unattended path asks first. This
  is the same line `sound_apply` sits on, and `Catalog.Sound` states the principle
  it belongs to: that verb is gated because it is *"the only one that changes what
  the machine does when nobody is watching."* Recording the room when nobody is
  watching is that category, only more so.

  ## The thing a caller must know about `sound_record`

  It records by spawning `ffmpeg`, and **on macOS that path may produce perfect,
  well-formed digital silence with a zero exit code** — because microphone consent
  is granted to the *responsible* process, and here the chain is
  `beam.smp` -> `ffmpeg`, out of `Contents/Resources`, with no `Info.plist` and no
  entitlement of its own. Verified on 08-09: a real capture returned exit 0, empty
  stderr, a valid 42 KB WAV, and 21,109 samples every one of which was exactly
  zero. **No consent prompt ever appeared** — consent is silently absent rather
  than denied.

  So `record/1` reads the result back and refuses a silent take rather than
  storing it, and this verb's description says so. It is a convenience for a
  trusted caller, not the operator's recording path; that one is the in-app
  recorder (`STUDIO_ROADMAP` V.6-V.8), which captures inside the signed app where
  consent can actually be attributed.
  """

  alias BusterClaw.Notifications.Capture
  alias BusterClaw.Notifications.Capture.Devices
  alias BusterClaw.Notifications.Capture.Level
  alias BusterClaw.Notifications.Cutup.Gaps

  @doc """
  Vocabulary coverage of the indexed corpus.

  `target` narrows the question to a vocabulary you care about and adds
  `missing` — the words in it with no take at all.
  """
  def sound_gaps(args \\ %{}) do
    opts =
      []
      |> put_opt(:limit, integer_arg(args, "limit"))
      |> put_opt(:target, Map.get(args, "target"))

    Gaps.report(opts)
  end

  @doc "Input devices available for recording."
  def sound_devices(_args \\ %{}) do
    with {:ok, devices} <- Devices.list() do
      {:ok, %{count: length(devices), devices: devices}}
    end
  end

  @doc "Current OS input volume, 0-100."
  def sound_input_level(_args \\ %{}) do
    with {:ok, volume} <- Level.get() do
      {:ok, %{volume: volume}}
    end
  end

  @doc "Set the OS input volume of the current default input device, 0-100."
  def sound_input_level_set(args) do
    case integer_arg(args, "volume") do
      nil ->
        {:error, :volume_required}

      volume ->
        # Report the previous value so the change can be undone. Best effort: a
        # machine with no controllable input answers `{:error, _}` here, and that
        # is not a reason to refuse the set.
        previous =
          case Level.get() do
            {:ok, was} -> was
            {:error, _reason} -> nil
          end

        with :ok <- Level.set(volume) do
          {:ok, %{volume: volume, previous: previous}}
        end
    end
  end

  @doc """
  Record from an input device into `sounds/studio/` as a new source.

  Refuses a silent capture rather than storing it — see the moduledoc.
  """
  def sound_record(args) do
    opts =
      []
      |> put_opt(:seconds, number_arg(args, "seconds"))
      |> put_opt(:name, Map.get(args, "name"))
      |> put_opt(:device, Map.get(args, "device"))

    Capture.record(opts)
  end

  # --- internals -------------------------------------------------------------

  # Only pass through what the caller actually supplied. Every one of these
  # domain functions has its own defaults and its own validation, and handing it
  # an explicit `nil` would override a default with a value it then has to reject.
  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # The CLI and JSON both arrive as strings; the LiveView and tests send numbers.
  # An unparseable value passes through as `nil` so the domain module's own
  # `required` error is what the caller sees, rather than a second vocabulary of
  # argument errors invented here.
  defp integer_arg(args, key) do
    case Map.get(args, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp number_arg(args, key) do
    case Map.get(args, key) do
      value when is_number(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> integer_arg(args, key)
        end

      _other ->
        nil
    end
  end
end
