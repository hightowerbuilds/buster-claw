defmodule BusterClaw.Telephony.Pins do
  @moduledoc """
  Caller-PIN management — the Mac-side half of the credential that caller ID is
  not (`supabase/migrations/*_phone_pins.sql`).

  Setting a PIN is the operator's job; verifying it is the `voice` edge
  function's. This module is only the write path from the Mac: it hashes a PIN
  at set-time and stores hash + salt in the Supabase `phone_pins` table over
  PostgREST, so the plaintext PIN never leaves this machine — it exists on the
  operator's keyboard and the caller's keypad, nowhere else. The edge function
  hashes the punched digits with the row's salt and compares.

  ## The hash contract (fixed, duplicated on the Deno side)

      pin_hash = lowercase_hex( sha256( utf8(salt) <> utf8(pin) ) )

  - `salt` is a random hex string, generated here at set-time, used verbatim.
  - `pin` is the literal digit string ("4815"), no normalization.
  - Concatenation is salt-then-pin, bytes, no separator.

  Any change here must land in `supabase/functions/_shared/pin.ts` in the same
  breath, or every stored PIN stops verifying. A short numeric PIN is
  low-entropy, so the hash is not the real defense — `failed_attempts` telemetry
  and a long-enough PIN are. The hash exists so a leak of `phone_pins` does not
  hand over plaintext PINs.

  ## Wire posture

  Same Supabase project, same service-role key, same PostgREST base as
  `BusterClaw.Telephony.Relay` and `.Drain` — the `phone_pins` table has RLS on
  with no policies, so only the service role can touch it. Fails **closed**: with
  no URL + key configured, every function returns `{:error, :not_configured}`
  rather than crashing. `req_options` (Req.Test plugs) inject in tests, exactly
  like the Relay/Drain clients.
  """

  # 4–10 digits, nothing else. Matches the edge-function expectation and keeps the
  # keypad honest; the plaintext is validated here and then only ever hashed.
  @pin_format ~r/^\d{4,10}$/

  alias BusterClaw.TrustedNumbers

  @doc "True when both the Supabase URL and service-role key are configured."
  def configured? do
    is_binary(url()) and url() != "" and is_binary(key()) and key() != ""
  end

  @doc """
  Set (or replace) the PIN for `number`.

  Normalizes `number` to E.164, validates `pin` is 4–10 digits, generates a fresh
  salt, computes the hash, and PostgREST-upserts the row (merge-duplicates on the
  `number` primary key), resetting `failed_attempts` to 0. Returns `{:ok, e164}`.

  `opts` carries the test seams: `:req_options` (Req plugs) and `:salt` (a fixed
  salt so a test can assert the exact stored hash). Neither is used in
  production — `set_pin/2` generates a strong random salt. The plaintext `pin`
  is never logged and never persisted; only its hash leaves this function.
  """
  def set_pin(number, pin, opts \\ []) do
    with true <- configured?() || {:error, :not_configured},
         {:ok, e164} <- normalize(number),
         :ok <- validate_pin(pin) do
      salt = Keyword.get(opts, :salt) || generate_salt()

      body = %{
        number: e164,
        pin_hash: hash_pin(salt, pin),
        salt: salt,
        failed_attempts: 0,
        updated_at: DateTime.utc_now()
      }

      request(opts)
      |> Req.merge(
        url: "/rest/v1/phone_pins",
        headers: [{"prefer", "resolution=merge-duplicates,return=minimal"}],
        json: body
      )
      |> Req.post()
      |> case do
        {:ok, %{status: status}} when status in 200..299 -> {:ok, e164}
        {:ok, %{status: status, body: b}} -> {:error, {:pins_status, status, b}}
        {:error, reason} -> {:error, {:pins_request_failed, reason}}
      end
    end
  end

  @doc """
  Remove the PIN for `number` (any form normalizing to the same E.164).
  Returns `:ok`, a no-op if no row exists (PostgREST DELETE is idempotent).
  """
  def remove_pin(number, opts \\ []) do
    with true <- configured?() || {:error, :not_configured},
         {:ok, e164} <- normalize(number) do
      request(opts)
      |> Req.merge(
        url: "/rest/v1/phone_pins",
        params: [number: "eq." <> e164],
        headers: [{"prefer", "return=minimal"}]
      )
      |> Req.delete()
      |> case do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: b}} -> {:error, {:pins_status, status, b}}
        {:error, reason} -> {:error, {:pins_request_failed, reason}}
      end
    end
  end

  @doc """
  The configured PINs as policy telemetry: number, failed-attempt count, and last
  verification time. Deliberately **never** selects `pin_hash` or `salt` — a hash
  is a credential and there is no reason to read it back onto this surface.
  Returns `{:ok, [map]}`.
  """
  def list_pins(opts \\ []) do
    with true <- configured?() || {:error, :not_configured} do
      request(opts)
      |> Req.merge(
        url: "/rest/v1/phone_pins",
        params: [select: "number,failed_attempts,last_verified_at"]
      )
      |> Req.get()
      |> case do
        {:ok, %{status: 200, body: rows}} when is_list(rows) -> {:ok, rows}
        {:ok, %{status: status, body: b}} -> {:error, {:pins_status, status, b}}
        {:error, reason} -> {:error, {:pins_request_failed, reason}}
      end
    end
  end

  @doc """
  The PIN hash, per the contract fixed with `supabase/functions/_shared/pin.ts`:
  `lowercase_hex(sha256(salt <> pin))`, salt-then-pin bytes, no separator.
  """
  def hash_pin(salt, pin) do
    :crypto.hash(:sha256, salt <> pin) |> Base.encode16(case: :lower)
  end

  # 16 random bytes as lowercase hex — the same shape the salt column expects and
  # the edge function reads back verbatim.
  defp generate_salt, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp normalize(number) do
    case TrustedNumbers.normalize(number) do
      {:ok, e164} -> {:ok, e164}
      :error -> {:error, :invalid_number}
    end
  end

  defp validate_pin(pin) when is_binary(pin) do
    if Regex.match?(@pin_format, pin), do: :ok, else: {:error, :invalid_pin}
  end

  defp validate_pin(_pin), do: {:error, :invalid_pin}

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
