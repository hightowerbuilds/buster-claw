defmodule BusterClaw.Integrations.Sentry do
  @moduledoc "Sentry issue polling and webhook normalization integration."

  @behaviour BusterClaw.Integrations.Service

  alias BusterClaw.Integrations.{Integration, Snapshot}

  @default_limit 10
  @event_sample_limit 3

  @impl true
  def fetch(%Integration{} = integration, opts \\ []) do
    with {:ok, org} <- required_config(integration, "org"),
         {:ok, project} <- required_config(integration, "project"),
         {:ok, issues} <-
           get_json(integration, issues_path(org, project), issue_params(integration), opts),
         {:ok, samples} <- fetch_event_samples(integration, org, issues, opts) do
      now = timestamp()
      source_url = source_url(integration, org, project)
      issues = Enum.take(List.wrap(issues), limit(integration))

      content =
        Snapshot.markdown(integration, %{
          title: "Sentry Issues Snapshot: #{project}",
          source: source_url,
          records: length(issues),
          summary: summary(issues),
          sections: sections(issues, samples)
        })

      {:ok,
       [
         %{
           date: DateTime.to_date(now),
           filename: Snapshot.filename(integration, "issues", now),
           source_url: source_url,
           name: "Sentry Issues Snapshot: #{project}",
           tags: ["integration", "sentry", "issues", "monitoring"],
           content: content,
           fetched_at: now
         }
       ]}
    end
  end

  @impl true
  def verify_webhook(%Integration{webhook_secret: secret}, _headers, _body)
      when secret in [nil, ""] do
    :ok
  end

  def verify_webhook(%Integration{webhook_secret: secret}, headers, body) do
    candidates = [
      header(headers, "x-buster-claw-secret"),
      bearer_token(header(headers, "authorization"))
    ]

    cond do
      Enum.any?(candidates, &secure_compare(secret, &1)) ->
        :ok

      signature = header(headers, "sentry-hook-signature") ->
        verify_hmac(secret, body, signature)

      true ->
        {:error, :unauthorized}
    end
  end

  @impl true
  def normalize_webhook(%Integration{} = integration, body) do
    with {:ok, payload} <- Jason.decode(body) do
      now = timestamp()
      action = webhook_action(payload)
      title = "Sentry Webhook Snapshot: #{action}"
      source_url = webhook_source_url(payload, integration)

      content =
        Snapshot.markdown(integration, %{
          title: title,
          source: source_url,
          records: 1,
          summary: webhook_summary(payload),
          sections: Snapshot.webhook_payload_sections(integration, payload)
        })

      {:ok,
       [
         %{
           date: DateTime.to_date(now),
           filename: Snapshot.filename(integration, "webhook-#{action}", now),
           source_url: source_url,
           name: title,
           tags: ["integration", "sentry", "webhook", "monitoring"],
           content: content,
           fetched_at: now
         }
       ]}
    end
  end

  defp fetch_event_samples(integration, org, issues, opts) do
    issues
    |> List.wrap()
    |> Enum.take(@event_sample_limit)
    |> Enum.reduce_while({:ok, %{}}, fn issue, {:ok, acc} ->
      case issue_id(issue) do
        nil ->
          {:cont, {:ok, acc}}

        id ->
          case get_json(integration, latest_event_path(org, id), [], opts) do
            {:ok, event} -> {:cont, {:ok, Map.put(acc, id, event)}}
            {:error, {:http_error, 404, _body}} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp get_json(integration, path, params, opts) do
    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        url: endpoint(integration, path),
        params: params,
        headers: headers(integration),
        receive_timeout: Keyword.get(opts, :timeout, 15_000),
        retry: false
      )

    case Req.get(req_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_params(integration) do
    config = integration.config || %{}

    [
      query: Map.get(config, "query", "is:unresolved"),
      limit: limit(integration)
    ]
    |> maybe_put(:environment, Map.get(config, "environment"))
  end

  defp summary([]), do: ["No unresolved issues returned."]

  defp summary(issues) do
    levels =
      issues
      |> Enum.map(&field(&1, ["level"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.map(fn {level, count} -> "#{level}: #{count}" end)
      |> Enum.join(", ")

    total_events =
      issues
      |> Enum.map(&integer_field(&1, ["count"]))
      |> Enum.sum()

    [
      "Issues returned: #{length(issues)}",
      "Total event count across returned issues: #{total_events}",
      "Levels: #{if levels == "", do: "unknown", else: levels}"
    ]
  end

  defp sections(issues, samples) do
    [
      "",
      "## Records",
      "",
      issue_records(issues, samples)
    ]
  end

  defp issue_records([], _samples), do: ["No records returned."]

  defp issue_records(issues, samples) do
    issues
    |> Enum.flat_map(fn issue ->
      id = issue_id(issue)
      sample = id && Map.get(samples, id)

      [
        "### #{Snapshot.value(first_field(issue, [["title"], ["metadata", "title"]]))}",
        "",
        "- ID: #{Snapshot.value(id)}",
        "- Short ID: #{Snapshot.value(first_field(issue, [["shortId"], ["short_id"]]))}",
        "- Level: #{Snapshot.value(field(issue, ["level"]))}",
        "- Status: #{Snapshot.value(field(issue, ["status"]))}",
        "- Count: #{Snapshot.value(field(issue, ["count"]))}",
        "- Users affected: #{Snapshot.value(first_field(issue, [["userCount"], ["user_count"]]))}",
        "- First seen: #{Snapshot.value(first_field(issue, [["firstSeen"], ["first_seen"]]))}",
        "- Last seen: #{Snapshot.value(first_field(issue, [["lastSeen"], ["last_seen"]]))}",
        "- Culprit: #{Snapshot.value(field(issue, ["culprit"]))}",
        "- URL: #{Snapshot.value(field(issue, ["permalink"]))}",
        "",
        event_excerpt(sample),
        ""
      ]
    end)
  end

  defp event_excerpt(nil), do: "No latest event sample returned."

  defp event_excerpt(event) do
    message =
      field(event, ["message", "title"]) ||
        first_field(event, [["message"], ["title"], ["metadata", "value"], ["metadata", "type"]])

    """
    Latest event sample:

    - Event ID: #{Snapshot.value(first_field(event, [["eventID"], ["event_id"], ["id"]]))}
    - Message: #{Snapshot.value(message)}
    - Timestamp: #{Snapshot.value(first_field(event, [["dateCreated"], ["datetime"], ["timestamp"]]))}
    """
    |> String.trim()
  end

  defp webhook_summary(payload) do
    [
      "Action: #{Snapshot.value(webhook_action(payload))}",
      "Issue: #{Snapshot.value(first_field(payload, [["data", "issue", "title"], ["issue", "title"]]))}",
      "Level: #{Snapshot.value(first_field(payload, [["data", "issue", "level"], ["level"]]))}",
      "URL: #{Snapshot.value(webhook_source_url(payload, nil))}"
    ]
  end

  defp webhook_action(payload) do
    first_field(payload, [["action"], ["resource"], ["data", "triggered_rule"]]) ||
      "event"
  end

  defp webhook_source_url(payload, nil) do
    first_field(payload, [["data", "issue", "permalink"], ["issue", "permalink"], ["url"]]) ||
      "sentry-webhook"
  end

  defp webhook_source_url(payload, integration) do
    webhook_source_url(payload, nil) ||
      String.trim_trailing(to_string(integration.base_url), "/")
  end

  defp required_config(%Integration{config: config}, key) do
    case Map.get(config || %{}, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end

  defp limit(%Integration{config: config}) do
    case Map.get(config || %{}, "limit") do
      value when is_integer(value) and value > 0 -> min(value, 100)
      value when is_binary(value) -> value |> Integer.parse() |> parsed_limit()
      _ -> @default_limit
    end
  end

  defp parsed_limit({value, ""}) when value > 0, do: min(value, 100)
  defp parsed_limit(_value), do: @default_limit

  defp issues_path(org, project) do
    "/projects/#{URI.encode_www_form(org)}/#{URI.encode_www_form(project)}/issues/"
  end

  defp latest_event_path(org, issue_id) do
    "/organizations/#{URI.encode_www_form(org)}/issues/#{URI.encode_www_form(to_string(issue_id))}/events/latest/"
  end

  defp source_url(integration, org, project), do: endpoint(integration, issues_path(org, project))

  defp endpoint(%Integration{base_url: base_url}, path) do
    String.trim_trailing(to_string(base_url), "/") <> path
  end

  defp headers(%Integration{token: token}) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}]
  end

  defp headers(_integration), do: [{"accept", "application/json"}]

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp issue_id(issue), do: field(issue, ["id"])

  defp integer_field(map, keys) do
    case field(map, keys) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> int_or_zero()
      _ -> 0
    end
  end

  defp int_or_zero({value, _rest}), do: value
  defp int_or_zero(:error), do: 0

  defp field(map, keys) when is_map(map), do: field_in(map, keys)
  defp field(_value, _keys), do: nil

  defp first_field(map, paths) do
    Enum.find_value(paths, &field(map, &1))
  end

  defp field_in(value, []), do: value

  defp field_in(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> field_in(value, rest)
      :error -> nil
    end
  end

  defp field_in(_value, _keys), do: nil

  defp header(headers, key) do
    headers
    |> Enum.find_value(fn {header, value} ->
      if String.downcase(header) == key, do: value
    end)
  end

  defp bearer_token("Bearer " <> token), do: token
  defp bearer_token("bearer " <> token), do: token
  defp bearer_token(_value), do: nil

  defp verify_hmac(secret, body, signature) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    signature = signature |> String.trim() |> String.trim_leading("sha256=") |> String.downcase()

    if secure_compare(expected, signature), do: :ok, else: {:error, :unauthorized}
  end

  defp secure_compare(expected, candidate) when is_binary(candidate) do
    expected = to_string(expected)

    if byte_size(expected) == byte_size(candidate) do
      expected
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(candidate))
      |> Enum.reduce(0, fn {left, right}, acc -> Bitwise.bor(acc, Bitwise.bxor(left, right)) end)
      |> Kernel.==(0)
    else
      false
    end
  end

  defp secure_compare(_expected, _candidate), do: false

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
