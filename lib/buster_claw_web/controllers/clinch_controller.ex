defmodule BusterClawWeb.ClinchController do
  @moduledoc """
  The Clinch's write path — the **only** one — reached by the desktop shell.

  - `POST /api/clinch` — store or replace a credential.
  - `DELETE /api/clinch` — forget one.
  - `POST /api/clinch/rotate` — re-encrypt everything under a new master key.

  There is deliberately **no GET**. Listing belongs to the LiveView, which reads
  `Clinch.list/0` and gets names and metadata; reading a *value* is not something
  any HTTP surface should be able to do, and adding it later would undo the
  design rather than extend it.

  ## Why this exists instead of a LiveView form

  A credential typed into a LiveView form travels as a `phx-change`/`phx-submit`
  payload, lands in the socket's assigns, and appears in the rendered diff. That
  is how integration tokens still round-trip to the browser in cleartext today
  (Clinch finding #5). Routing the write through the shell means the value goes
  from a plain DOM input straight to Tauri and then here — never through the
  LiveView channel, never into an assign, never into a diff. The leak class is
  closed by construction rather than by remembering to use `type="password"`.

  ## Who can reach it

  `:api_trusted` — `ApiAuth` then `RequireTrusted`. The full token only. It lives
  in the Keychain and the shell's process environment, so the shell can present
  it and a browser cannot, remote or local. See `BusterClawWeb.RequireTrusted`.
  """

  use BusterClawWeb, :controller

  alias BusterClaw.Clinch
  alias BusterClaw.Clinch.Rekey
  alias BusterClaw.Clinch.Types
  alias BusterClaw.RuntimeConfig

  def put(conn, %{"kind" => kind, "name" => name, "value" => value} = params)
      when is_binary(name) and is_binary(value) do
    with {:ok, kind} <- parse_kind(kind),
         {:ok, entry} <- Clinch.put({kind, name}, value, note: params["note"]) do
      # `entry` carries the kind, name and note — never the value. Serializing it
      # wholesale is safe *because* of that, and the Clinch tests assert it.
      json(conn, %{ok: true, entry: shape(entry)})
    else
      {:error, :unknown_kind} -> send_error(conn, 422, "unknown_kind")
      {:error, :unmanaged_kind} -> send_error(conn, 422, "unmanaged_kind")
      {:error, :missing_name_or_value} -> send_error(conn, 422, "missing_name_or_value")
      {:error, errors} when is_map(errors) -> send_error(conn, 422, "invalid", errors)
    end
  end

  def put(conn, _params), do: send_error(conn, 422, "missing_name_or_value")

  def delete(conn, %{"kind" => kind, "name" => name}) when is_binary(name) do
    with {:ok, kind} <- parse_kind(kind),
         {:ok, entry} <- Clinch.delete({kind, name}) do
      json(conn, %{ok: true, entry: shape(entry)})
    else
      {:error, :unknown_kind} -> send_error(conn, 422, "unknown_kind")
      {:error, :unmanaged_kind} -> send_error(conn, 422, "unmanaged_kind")
      {:error, :not_found} -> send_error(conn, 404, "not_found")
    end
  end

  def delete(conn, _params), do: send_error(conn, 422, "missing_name_or_value")

  # Kinds arrive as strings over the wire and must never be `String.to_atom/1`d —
  # that is an unbounded atom table keyed by request input. Matching against the
  # declared enum is both the safe conversion and the validation.
  @doc """
  Rotate the master key: re-encrypt every stored credential under `new_key`.

  **The caller supplies the new key and is responsible for keeping it.** This
  endpoint will not generate one, because the only copy of a master key must
  exist somewhere the operator chose before anything depends on it — a key this
  server invented and returned in a response is a key that lives, briefly, only
  in a log-shaped place.

  On success the running app switches to the new key immediately, so credentials
  keep resolving without a restart. **Persisting the key is the caller's job**
  (macOS Keychain, via the shell) and it is the step that makes the rotation
  survive a reboot — see `BusterClaw.Clinch.Rekey`.
  """
  def rotate(conn, %{"new_key" => new_key}) when is_binary(new_key) do
    case RuntimeConfig.secret_key_base() do
      current when is_binary(current) and current != "" ->
        do_rotate(conn, current, new_key)

      _ ->
        send_error(conn, 422, "no_current_key")
    end
  end

  def rotate(conn, _params), do: send_error(conn, 422, "missing_new_key")

  defp do_rotate(conn, current, new_key) do
    case Rekey.run(current, new_key) do
      {:ok, report} ->
        # The data now lives under the new key, so the running app must use it or
        # every subsequent read fails until restart. `System.put_env` is what
        # `RuntimeConfig.secret_key_base/0` reads first.
        System.put_env("SECRET_KEY_BASE", new_key)

        json(conn, %{
          ok: true,
          rekeyed: report.rekeyed,
          unreadable: report.unreadable,
          skipped: report.skipped
        })

      {:error, reason} ->
        send_error(conn, 422, to_string(reason))
    end
  end

  defp parse_kind(kind) when is_binary(kind) do
    case Enum.find(Types.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> {:error, :unknown_kind}
      found -> {:ok, found}
    end
  end

  defp parse_kind(_kind), do: {:error, :unknown_kind}

  defp shape(entry), do: %{kind: Atom.to_string(entry.kind), name: entry.name, note: entry.note}

  defp send_error(conn, status, error, details \\ nil) do
    body = %{ok: false, error: error}
    body = if details, do: Map.put(body, :details, details), else: body

    conn
    |> put_status(status)
    |> json(body)
  end
end
