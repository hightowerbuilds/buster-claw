defmodule BusterClaw.Telephony.Relay do
  @moduledoc """
  HTTP client for the Supabase relay — the durable queue between Twilio and
  this Mac (`supabase/migrations/*_telephony_events.sql`).

  Three wire calls, all against the project's PostgREST/Storage APIs with the
  service-role key (the relay table has RLS enabled with no policies, so only
  the service role can touch it):

  - `list_unsynced/1` — the queue read: rows the Edge Function inserted that
    this Mac hasn't drained yet, oldest first.
  - `download_recording/2` — voicemail audio from the private `recordings`
    bucket.
  - `delete_recording/2` + `delete_event/2` — ERASE the row and its audio once
    the Mac has it. The relay is a queue, not storage.

  Deliberately a poller's client, not a websocket: a Realtime subscription
  can't replay rows that arrived while the laptop slept, so a catch-up read
  has to exist anyway — this is that read, and at answering-machine latency
  it's the whole drain. `req_options` (Req.Test plugs) inject in tests.
  """

  alias BusterClaw.Clinch.AppKeys

  # Fixed, not per-render: the Edge Function has to be able to find it without
  # being told, and one greeting is the only thing a phone number can have.
  @greeting_path "greeting/greeting.wav"

  @doc "True when both the relay URL and service-role key are configured."
  def configured? do
    is_binary(url()) and url() != "" and is_binary(key()) and key() != ""
  end

  @doc """
  Unsynced relay rows, oldest first. Returns `{:ok, rows}` with string-keyed
  maps straight from PostgREST, or `{:error, reason}`.
  """
  def list_unsynced(opts \\ []) do
    request(opts)
    |> Req.merge(
      url: "/rest/v1/telephony_events",
      params: [
        select: "*",
        synced: "eq.false",
        order: "created_at.asc",
        limit: Keyword.get(opts, :limit, 50)
      ]
    )
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: rows}} when is_list(rows) -> {:ok, rows}
      {:ok, %{status: status, body: body}} -> {:error, {:relay_status, status, body}}
      {:error, reason} -> {:error, {:relay_request_failed, reason}}
    end
  end

  @doc """
  Voicemail audio bytes from the private `recordings` bucket.
  `{:error, :not_found}` means the object is genuinely gone (drain records the
  event without audio); any other failure is transient and retried next tick.
  """
  def download_recording(path, opts \\ []) when is_binary(path) do
    request(opts)
    |> Req.merge(url: "/storage/v1/object/recordings/" <> path)
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) -> {:ok, bytes}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:storage_status, status, body}}
      {:error, reason} -> {:error, {:storage_request_failed, reason}}
    end
  end

  @doc """
  Delete one voicemail object from the private `recordings` bucket.

  `{:ok, :gone}` for a 404 — the object is already absent, which is the state we
  wanted, so an absent object is success rather than an error to retry forever.

  Deleting is the point, not housekeeping: the relay is a **queue**, not storage.
  Audio sits in someone else's cloud only for as long as it takes this Mac to
  come and get it.
  """
  def delete_recording(path, opts \\ []) when is_binary(path) do
    request(opts)
    |> Req.merge(url: "/storage/v1/object/recordings/" <> path)
    |> Req.delete()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:ok, :gone}
      {:ok, %{status: status, body: body}} -> {:error, {:storage_status, status, body}}
      {:error, reason} -> {:error, {:storage_request_failed, reason}}
    end
  end

  @doc "Where the outgoing greeting lives. The Edge Function reads the same path."
  def greeting_path, do: @greeting_path

  @doc """
  Publish the outgoing greeting — the audio every caller hears before the beep.

  **This is the one durable object in a bucket that is otherwise a queue.**
  Everything else here exists to be deleted: voicemail audio sits in someone
  else's cloud only until this Mac comes and gets it. The greeting is the
  opposite — it is configuration, it is meant to persist, and it is *supposed* to
  be readable by a stranger, because a stranger phoning the number is exactly who
  hears it. It lives under the `greeting/` prefix, which nothing in the drain path
  ever enumerates or erases, so the two cannot collide.

  Upserts: re-publishing after editing the line must replace what callers hear,
  not fail because something is already there.
  """
  def upload_greeting(bytes, opts \\ []) when is_binary(bytes) do
    request(opts)
    |> Req.merge(
      url: "/storage/v1/object/recordings/" <> @greeting_path,
      headers: [{"content-type", "audio/wav"}, {"x-upsert", "true"}],
      body: bytes
    )
    |> Req.post()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:storage_status, status, body}}
      {:error, reason} -> {:error, {:storage_request_failed, reason}}
    end
  end

  @doc """
  Whether a greeting has been published.

  Answered by asking storage rather than by trusting a local flag: the object is
  what the phone line actually plays, and a Mac that was restored from a backup
  can hold a flag for audio that is not there.
  """
  def greeting_published?(opts \\ []) do
    request(opts)
    |> Req.merge(url: "/storage/v1/object/recordings/" <> @greeting_path)
    |> Req.head()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  @doc """
  Unpublish the greeting, putting callers back on the synthesized voice.

  A 404 is success: absent is the state being asked for.
  """
  def delete_greeting(opts \\ []) do
    request(opts)
    |> Req.merge(url: "/storage/v1/object/recordings/" <> @greeting_path)
    |> Req.delete()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:ok, :gone}
      {:ok, %{status: status, body: body}} -> {:error, {:storage_status, status, body}}
      {:error, reason} -> {:error, {:storage_request_failed, reason}}
    end
  end

  @doc """
  Delete one relay row. `id` is the row's uuid.

  **This replaced `mark_synced/2` on 2026-08-10, and the difference matters.**
  Flipping a `synced` flag left every voicemail transcript and every recording in
  the relay forever: `list_unsynced/1` filters them out, so drained rows became
  invisible rather than gone, and nothing ever collected them. Deleting makes the
  drain's own retry loop the erasure's retry loop too — a failed delete leaves the
  row listed, so the next tick tries again, where the local unique index on
  `twilio_sid` dedupes the re-read into a no-op.
  """
  def delete_event(id, opts \\ []) when is_binary(id) do
    request(opts)
    |> Req.merge(
      url: "/rest/v1/telephony_events",
      params: [id: "eq." <> id],
      headers: [{"prefer", "return=minimal"}]
    )
    |> Req.delete()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:relay_status, status, body}}
      {:error, reason} -> {:error, {:relay_request_failed, reason}}
    end
  end

  defp request(opts) do
    Req.new(
      base_url: url(),
      headers: [{"apikey", key()}, {"authorization", "Bearer " <> key()}],
      retry: false,
      receive_timeout: 30_000
    )
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end

  # Read live via the Clinch (env as fallback), never at boot — a key typed into
  # Settings must work without restarting the app, and a deleted one must stop
  # working on the next call. See `BusterClaw.Clinch.AppKeys`.
  defp url, do: AppKeys.get("supabase_url")
  defp key, do: AppKeys.get("supabase_service_role_key")
end
