defmodule BusterClaw.Telephony.Drain do
  @moduledoc """
  The Mac-side drain — the missing link in the BusterPhone call path.

  Twilio → Edge Function → Supabase queue happened in the cloud; this pump
  completes the wire: on a tick it reads unsynced rows from the relay
  (`BusterClaw.Telephony.Relay`), downloads voicemail audio into the Library,
  mirrors each row into local SQLite via `Telephony.record_event/2` (which
  broadcasts to `PhoneLive` and observes inbound events on Sentinel), and only
  then flips the remote row's `synced` flag.

  ## Discipline

  - **Persist-then-ack.** A row is marked synced only after the local insert
    succeeds. A crash in between re-drains the row next tick, where the local
    unique index on `twilio_sid` dedupes it — so the failure mode is a retry,
    never a lost voicemail.
  - **Transcript grace.** Twilio's transcription callback lands *after* the
    recording callback, and a drained row is never re-read. Voicemail rows with
    no transcript are left on the queue until they're older than the grace
    window, so the transcript has time to arrive before the one-shot drain.
  - **Rows fail independently.** One bad row logs and stays queued; the rest of
    the batch still drains. A recording that is genuinely gone (storage 404)
    drains without audio rather than blocking forever; transient storage
    failures leave the row queued for retry.
  - **Two-factor enqueue.** A drained voicemail only becomes agent work when the
    caller's number is trusted AND the call was PIN-verified (`verified` on the
    relay row). Either factor alone is a claim, not a caller — so both are
    required; a trusted number that skipped the PIN is recorded but never queued.

  Modeled on `BusterClaw.WalletPoller`: self-rescheduling tick, crash-safe tick
  body, `tick_now/1`, and injected `req_options` for tests.
  """
  use GenServer

  require Logger

  alias BusterClaw.Dispatch
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Event
  alias BusterClaw.Telephony.Relay
  alias BusterClaw.TrustedNumbers

  @default_interval_ms 30_000
  @default_transcript_grace_ms 180_000
  @recordings_dir "phone/recordings"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate drain pass (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          configured(:telephony_drain_tick_ms, @default_interval_ms)
        ),
      transcript_grace_ms:
        Keyword.get(
          opts,
          :transcript_grace_ms,
          configured(:telephony_drain_transcript_grace_ms, @default_transcript_grace_ms)
        ),
      req_options: Keyword.get(opts, :req_options, [])
    }

    if Keyword.get(opts, :autostart, true), do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_tick(fn -> drain(state) end)
    # Back-fill Twilio cost for any voicemail not yet finally priced. Cheap and
    # best-effort: only unpriced rows, no-op when Twilio isn't configured, and
    # isolated so a pricing hiccup never disturbs the drain. Prices lag, so this
    # naturally retries each tick until every component settles.
    safe_tick(fn -> Telephony.refresh_unpriced_costs() end)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def drain(state) do
    with true <- Relay.configured?(),
         {:ok, rows} <- Relay.list_unsynced(req_options: state.req_options) do
      ready = Enum.reject(rows, &awaiting_transcript?(&1, state.transcript_grace_ms))
      synced = Enum.count(ready, &(sync_row(&1, state) == :ok))

      if synced > 0 do
        Logger.info("Telephony drain: synced #{synced}/#{length(ready)} relay row(s)")
      end

      :ok
    else
      false -> :ok
      {:error, reason} -> Logger.warning("Telephony drain: relay read failed: #{inspect(reason)}")
    end
  end

  # The transcription callback trails the recording callback, and a drained row
  # is never re-read — so give young transcript-less voicemails time to finish.
  defp awaiting_transcript?(%{"kind" => "voicemail", "transcript" => nil} = row, grace_ms) do
    case parse_timestamp(row["created_at"]) do
      {:ok, created_at} -> DateTime.diff(DateTime.utc_now(), created_at, :millisecond) < grace_ms
      :error -> false
    end
  end

  defp awaiting_transcript?(_row, _grace_ms), do: false

  defp sync_row(row, state) do
    with {:ok, recording} <- fetch_recording(row, state),
         {:ok, attrs} <- event_attrs(row, recording),
         :ok <- persist(attrs) do
      ack(row, state)
    else
      {:error, reason} ->
        Logger.warning(
          "Telephony drain: row #{row["id"]} (#{row["twilio_sid"]}) failed: #{inspect(reason)}"
        )

        :error
    end
  end

  # {:ok, {local_relative_path, flags}} — audio saved under the Library root,
  # or nil path when the row has no recording / the object is gone (404).
  defp fetch_recording(%{"recording_path" => path} = _row, state) when is_binary(path) do
    with {:ok, relative} <- safe_recording_path(path),
         {:ok, bytes} <- Relay.download_recording(path, req_options: state.req_options) do
      absolute = Path.join(Artifact.root(), relative)

      with :ok <- File.mkdir_p(Path.dirname(absolute)),
           :ok <- File.write(absolute, bytes) do
        {:ok, {relative, %{}}}
      end
    else
      # Genuinely gone: drain the event without audio instead of retrying forever.
      {:error, :not_found} -> {:ok, {nil, %{"recording_missing" => true}}}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_recording(_row, _state), do: {:ok, {nil, %{}}}

  # The relay path is written by our own Edge Function, but it lands inside the
  # Library root and gets served back by TelephonyRecordingController — refuse
  # anything that would escape rather than trusting the cloud row.
  defp safe_recording_path(path) do
    case Path.safe_relative(path) do
      {:ok, safe} -> {:ok, Path.join(@recordings_dir, safe)}
      :error -> {:error, {:unsafe_recording_path, path}}
    end
  end

  defp event_attrs(row, {recording_path, flags}) do
    case parse_timestamp(row["created_at"]) do
      {:ok, occurred_at} ->
        {:ok,
         %{
           direction: row["direction"],
           kind: row["kind"],
           from_number: row["from_number"],
           to_number: row["to_number"],
           body: row["body"],
           duration_seconds: row["duration_seconds"],
           transcript: row["transcript"],
           twilio_sid: row["twilio_sid"],
           # The caller-PIN verdict from the edge function. Absent/nil means the
           # gate never ran (older function build, or a path that skipped it) —
           # default false, NEVER true, so an ungated row is untrusted work.
           verified: row["verified"] == true,
           recording_path: recording_path,
           occurred_at: occurred_at,
           metadata:
             row
             |> Map.get("metadata", %{})
             |> normalize_metadata()
             |> Map.merge(%{"relay_id" => row["id"]})
             |> Map.merge(flags)
         }}

      :error ->
        {:error, {:bad_created_at, row["created_at"]}}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp persist(attrs) do
    case Telephony.record_event(attrs) do
      {:ok, event} ->
        maybe_enqueue_dispatch(event)
        :ok

      {:error, changeset} ->
        if duplicate?(changeset), do: :ok, else: {:error, changeset}
    end
  end

  # A voicemail becomes agent work only when BOTH gates open: the caller's number
  # is trusted AND the call was PIN-verified. Two independent factors, because
  # each alone is a claim, not a caller — caller ID is trivially spoofable, and a
  # PIN proves knowledge but not that this is a number we've chosen to trust. A
  # stranger's voicemail, or a trusted number that never punched the PIN, is
  # recorded and playable in the Message Machine but never enqueued — see
  # `BusterClaw.TrustedNumbers` for why an untrusted item on the queue is
  # dangerous (short version: an answering machine records strangers by design,
  # and the provenance gate is per-run, so one robocall in the open pool would
  # downgrade the whole shift's token).
  #
  # A trusted number that called WITHOUT verifying is logged: it's the operator
  # (or a spoofer of the operator) who didn't punch their PIN, and either way the
  # near-miss is worth seeing rather than swallowing silently.
  #
  # Best-effort, exactly like the Gmail path: a dedupe conflict on re-drain is
  # expected and stays quiet, and no error can fail the drain and strand a
  # voicemail — but an *unexpected* enqueue failure is logged, because it means
  # a trusted caller's voicemail silently never became agent work.
  defp maybe_enqueue_dispatch(%Event{direction: "inbound", kind: "sms"} = event) do
    cond do
      compliance_message?(event) ->
        :skip

      number = TrustedNumbers.match(event.from_number) ->
        event
        |> Dispatch.enqueue_sms(%{
          trusted: true,
          trusted_sender: number,
          recommended_role_key: "sms-triage",
          request_summary: "Text message from #{number}",
          metadata: %{"telephony_event_id" => event.id}
        })
        |> log_enqueue_failure("SMS #{event.twilio_sid}")

      true ->
        :skip
    end
  end

  defp maybe_enqueue_dispatch(%Event{direction: "inbound", kind: "voicemail"} = event) do
    case TrustedNumbers.match(event.from_number) do
      nil ->
        :skip

      number ->
        if event.verified do
          event
          |> Dispatch.enqueue_voicemail(%{
            trusted: true,
            trusted_sender: number,
            recommended_role_key: "voicemail-triage",
            request_summary: request_summary(event),
            metadata: %{
              "telephony_event_id" => event.id,
              "recording_path" => event.recording_path
            }
          })
          |> log_enqueue_failure("voicemail #{event.twilio_sid}")
        else
          Logger.warning(
            "Telephony drain: trusted number #{number} called without PIN verification — " <>
              "recorded but NOT enqueued (voicemail #{event.twilio_sid})"
          )

          :skip
        end
    end
  end

  defp maybe_enqueue_dispatch(_event), do: :skip

  # Twilio's Advanced Opt-Out flow owns these exchanges. Archive them, but do
  # not let an agent send a second response or reinterpret a compliance command
  # as work. The body check also fails safe when Advanced Opt-Out is not enabled.
  defp compliance_message?(%Event{metadata: metadata, body: body}) do
    opt_out_type = metadata && (metadata["opt_out_type"] || metadata[:opt_out_type])

    present?(opt_out_type) or
      body
      |> to_string()
      |> String.trim()
      |> String.upcase()
      |> then(&(&1 in ~w(STOP STOPALL UNSUBSCRIBE CANCEL END QUIT START UNSTOP HELP INFO)))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  # Dedupe conflicts (re-drain of an already-queued voicemail) are expected and
  # stay quiet; anything else is a trusted voicemail that never reached the
  # queue, which must not vanish without a trace.
  defp log_enqueue_failure({:ok, _item}, _what), do: :ok

  defp log_enqueue_failure({:error, %Ecto.Changeset{errors: errors}}, what) do
    unless Keyword.has_key?(errors, :dedupe_key) do
      Logger.error("Telephony drain: #{what} failed to enqueue: #{inspect(errors)}")
    end

    :ok
  end

  defp log_enqueue_failure({:error, reason}, what) do
    Logger.error("Telephony drain: #{what} failed to enqueue: #{inspect(reason)}")
    :ok
  end

  defp request_summary(%Event{transcript: nil} = event),
    do: "Voicemail from #{event.from_number} (no transcript)"

  defp request_summary(%Event{} = event), do: "Voicemail from #{event.from_number}"

  # A re-drained row (crash between persist and ack) trips the local unique
  # index on twilio_sid — that means we already have it, so just ack.
  defp duplicate?(%Ecto.Changeset{errors: errors}) do
    case errors[:twilio_sid] do
      {_message, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  defp ack(row, state) do
    case Relay.mark_synced(row["id"], req_options: state.req_options) do
      :ok ->
        :ok

      {:error, reason} ->
        # Local row exists; next tick re-drains and dedupes back to this ack.
        Logger.warning("Telephony drain: ack failed for #{row["id"]}: #{inspect(reason)}")
        :error
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp safe_tick(fun) do
    fun.()
  rescue
    exception -> Logger.warning("Telephony drain: tick failed: #{Exception.message(exception)}")
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
