defmodule BusterClaw.Commands.Schema do
  @moduledoc """
  Convert a `BusterClaw.Commands` arg spec into JSON-Schema-shaped maps used
  by MCP `tools/list` and provider-native tool definitions.
  """

  @doc """
  Convert an args spec map (`%{"id" => %{type: :integer, required: true}}`)
  into a JSON Schema object.
  """
  def to_json_schema(args) when map_size(args) == 0 do
    %{type: "object", properties: %{}, required: []}
  end

  def to_json_schema(args) do
    properties =
      Enum.into(args, %{}, fn {name, spec} ->
        {to_string(name), arg_property(spec)}
      end)

    required =
      args
      |> Enum.filter(fn {_, spec} -> Map.get(spec, :required, false) end)
      |> Enum.map(fn {name, _} -> to_string(name) end)

    %{
      type: "object",
      properties: properties,
      required: required
    }
  end

  defp arg_property(spec) do
    %{type: json_type(Map.get(spec, :type, :string))}
    |> maybe_put(:description, Map.get(spec, :description))
    |> maybe_put(:enum, Map.get(spec, :enum))
    |> maybe_put(:default, Map.get(spec, :default))
  end

  defp json_type(:string), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:boolean), do: "boolean"
  defp json_type(:map), do: "object"
  defp json_type(:array), do: "array"
  defp json_type(_), do: "string"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
