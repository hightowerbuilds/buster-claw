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
  - `mark_synced/2` — flip `synced` after the row is safely in local SQLite.

  Deliberately a poller's client, not a websocket: a Realtime subscription
  can't replay rows that arrived while the laptop slept, so a catch-up read
  has to exist anyway — this is that read, and at answering-machine latency
  it's the whole drain. `req_options` (Req.Test plugs) inject in tests.
  """

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

  @doc "Mark one relay row drained. `id` is the row's uuid."
  def mark_synced(id, opts \\ []) when is_binary(id) do
    request(opts)
    |> Req.merge(
      url: "/rest/v1/telephony_events",
      params: [id: "eq." <> id],
      headers: [{"prefer", "return=minimal"}],
      json: %{synced: true}
    )
    |> Req.patch()
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

  defp url, do: Application.get_env(:buster_claw, :telephony_relay_url)
  defp key, do: Application.get_env(:buster_claw, :telephony_relay_key)
end
