defmodule BusterClawWeb.ClinchController do
  @moduledoc """
  The Clinch's write path — the **only** one — reached by the desktop shell.

  - `POST /api/clinch` — store or replace a credential.
  - `DELETE /api/clinch` — forget one.

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
  alias BusterClaw.Clinch.Types

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
