defmodule BusterClaw.Integrations.Snapshot do
  @moduledoc "Markdown snapshot helpers for operational integrations."

  alias BusterClaw.Integrations.Integration

  @default_payload_excerpt_limit 8_000
  @max_payload_excerpt_limit 20_000
  @redacted "[redacted]"
  @sensitive_key_fragments ~w(
    authorization
    accesstoken
    apikey
    clientsecret
    cookie
    csrf
    idtoken
    password
    passwd
    privatekey
    refreshtoken
    secret
    session
    signature
    token
  )

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

  def inspect_block(value, limit \\ @default_payload_excerpt_limit) do
    value
    |> inspect(pretty: true, limit: 50, printable_limit: limit)
    |> bounded(limit)
  end

  def webhook_payload_sections(%Integration{} = integration, payload) do
    case payload_excerpt_policy(integration) do
      :none ->
        []

      {:redacted_excerpt, limit} ->
        [
          "",
          "## Payload Excerpt",
          "",
          "- Retention: redacted excerpt, capped at #{limit} characters.",
          "",
          "```elixir",
          payload |> redact_sensitive() |> inspect_block(limit),
          "```"
        ]
    end
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

  defp payload_excerpt_policy(%Integration{config: config}) do
    config = config || %{}

    if excerpt_disabled?(Map.get(config, "webhook_payload_excerpt", true)) do
      :none
    else
      {:redacted_excerpt, payload_excerpt_limit(config)}
    end
  end

  defp excerpt_disabled?(value) when value in [false, 0], do: true

  defp excerpt_disabled?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["0", "false", "none", "off", "disabled", "no"]))
  end

  defp excerpt_disabled?(_value), do: false

  defp payload_excerpt_limit(config) do
    config
    |> Map.get("webhook_payload_excerpt_limit", @default_payload_excerpt_limit)
    |> parse_limit()
    |> min(@max_payload_excerpt_limit)
  end

  defp parse_limit(value) when is_integer(value) and value > 0, do: value

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> limit
      _other -> @default_payload_excerpt_limit
    end
  end

  defp parse_limit(_value), do: @default_payload_excerpt_limit

  defp redact_sensitive(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact_sensitive(nested)}
      end
    end)
  end

  defp redact_sensitive(value) when is_list(value), do: Enum.map(value, &redact_sensitive/1)
  defp redact_sensitive(value), do: value

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")

    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp bounded(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n[truncated]",
      else: text
  end
end
