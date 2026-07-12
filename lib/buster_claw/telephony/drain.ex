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

  Modeled on `BusterClaw.WalletPoller`: self-rescheduling tick, crash-safe tick
  body, `tick_now/1`, and injected `req_options` for tests.
  """
  use GenServer

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Relay

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
           recording_path: recording_path,
           occurred_at: occurred_at,
           metadata: Map.merge(%{"relay_id" => row["id"]}, flags)
         }}

      :error ->
        {:error, {:bad_created_at, row["created_at"]}}
    end
  end

  defp persist(attrs) do
    case Telephony.record_event(attrs) do
      {:ok, _event} -> :ok
      {:error, changeset} -> if duplicate?(changeset), do: :ok, else: {:error, changeset}
    end
  end

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
