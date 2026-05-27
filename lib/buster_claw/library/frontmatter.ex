defmodule BusterClaw.Library.Frontmatter do
  @moduledoc "Small frontmatter builder/parser for local markdown artifacts."

  @doc "Build a YAML-like frontmatter block from a map."
  def build(fields) when is_map(fields) do
    fields =
      fields
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{encode_value(value)}" end)

    if fields == "" do
      ""
    else
      "---\n#{fields}\n---\n\n"
    end
  end

  @doc """
  Split markdown into parsed frontmatter fields and body.

  Only the simple shapes Buster Claw writes and imports are supported: strings,
  numbers, booleans, JSON-style lists/maps, and quoted strings.
  """
  def split(markdown) when is_binary(markdown) do
    markdown = String.replace(markdown, "\r\n", "\n")

    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*(?:\n|$)(.*)\z/s, markdown) do
      [_, raw_fields, body] ->
        %{fields: parse_fields(raw_fields), body: String.trim_leading(body)}

      _ ->
        %{fields: %{}, body: markdown}
    end
  end

  defp parse_fields(raw_fields) do
    raw_fields
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          Map.put(acc, String.trim(key), parse_value(String.trim(value)))

        _ ->
          acc
      end
    end)
  end

  defp parse_value(""), do: ""

  defp parse_value(value) do
    cond do
      quoted?(value) ->
        value
        |> String.slice(1, String.length(value) - 2)
        |> String.replace(~s(\\"), ~s("))
        |> String.replace("\\\\", "\\")

      String.starts_with?(value, "[") or String.starts_with?(value, "{") ->
        parse_json_value(value)

      value in ["true", "false"] ->
        value == "true"

      Regex.match?(~r/\A-?\d+\z/, value) ->
        String.to_integer(value)

      true ->
        value
    end
  end

  defp parse_json_value(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp quoted?(value) do
    String.length(value) >= 2 and String.starts_with?(value, ~s(")) and
      String.ends_with?(value, ~s("))
  end

  defp encode_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
    |> then(&~s("#{&1}"))
  end

  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_boolean(value), do: to_string(value)

  defp encode_value(%DateTime{} = value), do: ~s("#{DateTime.to_iso8601(value)}")
  defp encode_value(%Date{} = value), do: ~s("#{Date.to_iso8601(value)}")
  defp encode_value(%Time{} = value), do: ~s("#{Time.to_iso8601(value)}")

  defp encode_value(value) when is_list(value) or is_map(value) do
    Jason.encode!(value)
  end

  defp encode_value(value), do: value |> to_string() |> encode_value()
end
