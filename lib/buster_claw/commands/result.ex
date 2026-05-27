defmodule BusterClaw.Commands.Result do
  @moduledoc """
  Converts `BusterClaw.Commands.*` return values into JSON-friendly maps.

  Handles Ecto structs, DateTime/Date/Time, unloaded associations, and nested
  lists/maps. Used by the HTTP API and MCP frontends.
  """

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
    |> Enum.into(%{}, fn {k, v} -> {k, sanitize(v)} end)
  end

  def to_json(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} -> {k, to_json(v)} end)
  end

  def to_json(value), do: value

  defp sanitize(%Ecto.Association.NotLoaded{}), do: nil
  defp sanitize(value), do: to_json(value)
end
