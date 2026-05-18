defmodule BusterClaw.Integrations.Snapshot do
  @moduledoc "Markdown snapshot helpers for operational integrations."

  alias BusterClaw.Integrations.Integration

  def filename(%Integration{} = integration, suffix, now \\ DateTime.utc_now()) do
    stamp = now |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    service = slug(integration.service_type || "integration")
    name = slug(integration.name || service)
    suffix = slug(suffix)

    Enum.join([service, name, suffix, stamp], "-") <> ".md"
  end

  def markdown(%Integration{} = integration, attrs) do
    service = service_label(integration.service_type)
    title = Map.fetch!(attrs, :title)
    source = Map.fetch!(attrs, :source)
    records = Map.get(attrs, :records, 0)
    summary = Map.get(attrs, :summary, [])
    sections = Map.get(attrs, :sections, [])
    window = Map.get(attrs, :window)

    [
      "# #{title}",
      "",
      "- Service: #{service}",
      "- Integration: #{integration.name}",
      optional_line("Window", window),
      "- Records: #{records}",
      "- Source: #{source}",
      "",
      "## Summary",
      "",
      list(summary),
      "",
      sections
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  def inspect_block(value) do
    value
    |> inspect(pretty: true, limit: 50, printable_limit: 4_000)
    |> bounded()
  end

  def value(value) when value in [nil, ""], do: "unknown"
  def value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  def value(value), do: to_string(value)

  defp optional_line(_label, nil), do: nil
  defp optional_line(_label, ""), do: nil
  defp optional_line(label, value), do: "- #{label}: #{value}"

  defp list([]), do: "- No summary data returned."
  defp list(items), do: Enum.map(items, &"- #{&1}")

  defp service_label("github"), do: "GitHub"
  defp service_label("sentry"), do: "Sentry"
  defp service_label("umami"), do: "Umami"
  defp service_label(service), do: String.capitalize(to_string(service || "Integration"))

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "snapshot"
      slug -> slug
    end
  end

  defp bounded(text, limit \\ 8_000) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n[truncated]",
      else: text
  end
end
