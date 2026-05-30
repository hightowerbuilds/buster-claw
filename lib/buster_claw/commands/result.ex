defmodule BusterClaw.Commands.Result do
  @moduledoc """
  Converts `BusterClaw.Commands.*` return values into JSON-friendly maps.

  Handles Ecto structs, DateTime/Date/Time, unloaded associations, and nested
  lists/maps. Used by the HTTP API and MCP frontends.

  Secret-bearing fields (API keys, tokens, webhook secrets, and any encrypted
  `*_enc` column) are redacted so that no frontend — including the chat agent's
  tool loop, which may be driven by prompt-injected content — can read or
  exfiltrate stored credentials. Presence is preserved (`"[REDACTED]"`) so
  callers can still tell a secret is set without learning its value.
  """

  # Field names whose values must never be serialized in cleartext.
  @redacted_fields ~w(
    api_key secret token webhook_secret client_secret refresh_token
    access_token password
  )a

  @redacted_placeholder "[REDACTED]"

  def to_json({status, value}) when status in [:ok, :error] do
    %{status: to_string(status), value: to_json(value)}
  end

  def to_json(value) when is_list(value), do: Enum.map(value, &to_json/1)
  def to_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def to_json(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  def to_json(%Date{} = d), do: Date.to_iso8601(d)
  def to_json(%Time{} = t), do: Time.to_iso8601(t)

  def to_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Enum.into(%{}, fn {k, v} -> {k, redact(k, v)} end)
  end

  def to_json(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} -> {k, to_json(v)} end)
  end

  def to_json(value), do: value

  # Redact known-sensitive fields and any encrypted column (`*_enc`). A set
  # secret becomes a placeholder; an unset one stays nil so presence is clear.
  defp redact(key, value) do
    if redacted_field?(key) do
      if is_nil(value), do: nil, else: @redacted_placeholder
    else
      sanitize(value)
    end
  end

  defp redacted_field?(key) when is_atom(key) do
    key in @redacted_fields or String.ends_with?(Atom.to_string(key), "_enc")
  end

  defp redacted_field?(_key), do: false

  defp sanitize(%Ecto.Association.NotLoaded{}), do: nil
  defp sanitize(value), do: to_json(value)
end
