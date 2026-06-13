defmodule BusterClaw.Integrations.GitHub do
  @moduledoc "GitHub repository activity polling and webhook normalization integration."

  @behaviour BusterClaw.Integrations.Service

  alias BusterClaw.Integrations.{Integration, Snapshot}

  @default_limit 10

  @fetch_concurrency 6

  @impl true
  def fetch(%Integration{} = integration, opts \\ []) do
    with {:ok, owner} <- required_config(integration, "owner"),
         {:ok, repo} <- required_config(integration, "repo"),
         {:ok,
          %{
            commits: commits,
            open_prs: open_prs,
            closed_prs: closed_prs,
            issues: issues,
            workflow_runs: workflow_runs,
            releases: releases
          }} <- fetch_activity(integration, owner, repo, opts) do
      now = timestamp()
      source_url = source_url(owner, repo)

      merged_prs =
        Enum.filter(List.wrap(closed_prs), &(field(&1, ["merged_at"]) not in [nil, ""]))

      content =
        Snapshot.markdown(integration, %{
          title: "GitHub Activity Snapshot: #{owner}/#{repo}",
          source: source_url,
          records:
            Enum.sum([
              length(List.wrap(commits)),
              length(List.wrap(open_prs)),
              length(merged_prs),
              length(List.wrap(issues)),
              length(List.wrap(workflow_runs)),
              length(List.wrap(releases))
            ]),
          summary: summary(commits, open_prs, merged_prs, issues, workflow_runs, releases),
          sections: sections(commits, open_prs, merged_prs, issues, workflow_runs, releases)
        })

      {:ok,
       [
         %{
           date: DateTime.to_date(now),
           filename: Snapshot.filename(integration, "activity", now),
           source_url: source_url,
           name: "GitHub Activity Snapshot: #{owner}/#{repo}",
           tags: ["integration", "github", "activity", "monitoring"],
           content: content,
           fetched_at: now
         }
       ]}
    end
  end

  # The six activity calls are independent GitHub REST reads with no inter-
  # dependency, so we fan them out concurrently instead of summing their
  # latencies in a sequential `with` chain. Each task carries its own HTTP call
  # (`get_json` keeps its own `receive_timeout`, so the stream uses
  # `timeout: :infinity`). We propagate the first error to preserve the previous
  # short-circuit semantics; on success the named fields are reassembled.
  defp fetch_activity(integration, owner, repo, opts) do
    calls = [
      {:commits,
       fn ->
         get_json(
           integration,
           repo_path(owner, repo, "/commits"),
           commit_params(integration),
           opts
         )
       end},
      {:open_prs,
       fn ->
         get_json(
           integration,
           repo_path(owner, repo, "/pulls"),
           pull_params("open", integration),
           opts
         )
       end},
      {:closed_prs,
       fn ->
         get_json(
           integration,
           repo_path(owner, repo, "/pulls"),
           pull_params("closed", integration),
           opts
         )
       end},
      {:issues, fn -> fetch_issues(integration, owner, repo, opts) end},
      {:workflow_runs, fn -> fetch_workflow_runs(integration, owner, repo, opts) end},
      {:releases,
       fn ->
         get_json(
           integration,
           repo_path(owner, repo, "/releases"),
           limit_params(integration),
           opts
         )
       end}
    ]

    calls
    |> Task.async_stream(
      fn {key, call} -> {key, call.()} end,
      max_concurrency: @fetch_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {key, {:ok, value}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, key, value)}}
      {:ok, {_key, {:error, reason}}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:fetch_task_exit, reason}}}
    end)
  end

  @impl true
  def verify_webhook(%Integration{webhook_secret: secret}, _headers, _body)
      when secret in [nil, ""] do
    :ok
  end

  def verify_webhook(%Integration{webhook_secret: secret}, headers, body) do
    case header(headers, "x-hub-signature-256") do
      nil -> {:error, :unauthorized}
      signature -> verify_hmac(secret, body, signature)
    end
  end

  @impl true
  def normalize_webhook(%Integration{} = integration, body) do
    with {:ok, payload} <- Jason.decode(body) do
      now = timestamp()
      event = webhook_event(payload)
      action = field(payload, ["action"]) || "received"
      title = "GitHub Webhook Snapshot: #{event}.#{action}"
      source_url = webhook_source_url(payload)

      content =
        Snapshot.markdown(integration, %{
          title: title,
          source: source_url,
          records: 1,
          summary: webhook_summary(event, action, payload),
          sections: Snapshot.webhook_payload_sections(integration, payload)
        })

      {:ok,
       [
         %{
           date: DateTime.to_date(now),
           filename: Snapshot.filename(integration, "webhook-#{event}-#{action}", now),
           source_url: source_url,
           name: title,
           tags: ["integration", "github", "webhook", "monitoring"],
           content: content,
           fetched_at: now
         }
       ]}
    end
  end

  defp fetch_issues(integration, owner, repo, opts) do
    if disabled?(integration, "include_issues") do
      {:ok, []}
    else
      with {:ok, issues} <-
             get_json(
               integration,
               repo_path(owner, repo, "/issues"),
               issue_params(integration),
               opts
             ) do
        {:ok, Enum.reject(List.wrap(issues), &Map.has_key?(&1, "pull_request"))}
      end
    end
  end

  defp fetch_workflow_runs(integration, owner, repo, opts) do
    if disabled?(integration, "include_workflows") do
      {:ok, []}
    else
      with {:ok, %{"workflow_runs" => runs}} <-
             get_json(
               integration,
               repo_path(owner, repo, "/actions/runs"),
               limit_params(integration),
               opts
             ) do
        {:ok, List.wrap(runs)}
      end
    end
  end

  defp disabled?(%Integration{config: config}, key) when is_map(config), do: config[key] == false
  defp disabled?(_integration, _key), do: true

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

  defp summary(commits, open_prs, merged_prs, issues, workflow_runs, releases) do
    failed_runs =
      workflow_runs
      |> List.wrap()
      |> Enum.count(&(field(&1, ["conclusion"]) in ["failure", "timed_out", "cancelled"]))

    [
      "Recent commits: #{length(List.wrap(commits))}",
      "Open pull requests: #{length(List.wrap(open_prs))}",
      "Recently merged pull requests: #{length(List.wrap(merged_prs))}",
      "Open issues: #{length(List.wrap(issues))}",
      "Workflow runs: #{length(List.wrap(workflow_runs))} (#{failed_runs} failed or cancelled)",
      "Releases: #{length(List.wrap(releases))}"
    ]
  end

  defp sections(commits, open_prs, merged_prs, issues, workflow_runs, releases) do
    [
      section("Recent Commits", commits, &commit_row/1),
      section("Open Pull Requests", open_prs, &pull_request_row/1),
      section("Recently Merged Pull Requests", merged_prs, &pull_request_row/1),
      section("Open Issues", issues, &issue_row/1),
      section("Workflow Runs", workflow_runs, &workflow_run_row/1),
      section("Releases", releases, &release_row/1)
    ]
  end

  defp section(title, records, row_fun) do
    [
      "",
      "## #{title}",
      "",
      rows(records, row_fun)
    ]
  end

  defp rows(records, row_fun) do
    records = List.wrap(records)

    if records == [] do
      ["- No records returned."]
    else
      records
      |> Enum.take(@default_limit)
      |> Enum.map(row_fun)
    end
  end

  defp commit_row(commit) do
    sha = commit |> field(["sha"]) |> Snapshot.value() |> String.slice(0, 7)
    message = first_line(field(commit, ["commit", "message"]))
    author = field(commit, ["commit", "author", "name"])
    url = field(commit, ["html_url"])

    "- #{sha} #{Snapshot.value(message)} by #{Snapshot.value(author)} (#{Snapshot.value(url)})"
  end

  defp pull_request_row(pr) do
    "- ##{Snapshot.value(field(pr, ["number"]))} #{Snapshot.value(field(pr, ["title"]))} by #{Snapshot.value(field(pr, ["user", "login"]))} (#{Snapshot.value(field(pr, ["html_url"]))})"
  end

  defp issue_row(issue) do
    "- ##{Snapshot.value(field(issue, ["number"]))} #{Snapshot.value(field(issue, ["title"]))} by #{Snapshot.value(field(issue, ["user", "login"]))} (#{Snapshot.value(field(issue, ["html_url"]))})"
  end

  defp workflow_run_row(run) do
    "- #{Snapshot.value(field(run, ["name"]))}: #{Snapshot.value(field(run, ["status"]))}/#{Snapshot.value(field(run, ["conclusion"]))} on #{Snapshot.value(field(run, ["head_branch"]))} (#{Snapshot.value(field(run, ["html_url"]))})"
  end

  defp release_row(release) do
    "- #{Snapshot.value(field(release, ["tag_name"]))}: #{Snapshot.value(field(release, ["name"]))} (#{Snapshot.value(field(release, ["html_url"]))})"
  end

  defp webhook_summary(event, action, payload) do
    repo = first_field(payload, [["repository", "full_name"], ["repo", "full_name"]])

    [
      "Event: #{event}",
      "Action: #{action}",
      "Repository: #{Snapshot.value(repo)}",
      "Ref: #{Snapshot.value(field(payload, ["ref"]))}",
      "Sender: #{Snapshot.value(field(payload, ["sender", "login"]))}",
      "URL: #{Snapshot.value(webhook_source_url(payload))}"
    ]
  end

  defp webhook_event(payload) do
    cond do
      field(payload, ["workflow_run"]) -> "workflow_run"
      field(payload, ["pull_request"]) -> "pull_request"
      field(payload, ["issue"]) -> "issues"
      field(payload, ["release"]) -> "release"
      field(payload, ["commits"]) -> "push"
      true -> "event"
    end
  end

  defp webhook_source_url(payload) do
    first_field(payload, [
      ["pull_request", "html_url"],
      ["issue", "html_url"],
      ["release", "html_url"],
      ["workflow_run", "html_url"],
      ["repository", "html_url"]
    ]) || "github-webhook"
  end

  defp required_config(%Integration{config: config}, key) do
    case Map.get(config || %{}, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end

  defp commit_params(integration) do
    integration
    |> limit_params()
    |> maybe_put(:sha, Map.get(integration.config || %{}, "branch"))
  end

  defp pull_params(state, integration) do
    integration
    |> limit_params()
    |> Keyword.merge(state: state, sort: "updated", direction: "desc")
  end

  defp issue_params(integration) do
    integration
    |> limit_params()
    |> Keyword.merge(state: "open")
  end

  defp limit_params(integration), do: [per_page: limit(integration)]

  defp limit(%Integration{config: config}) do
    case Map.get(config || %{}, "limit") do
      value when is_integer(value) and value > 0 -> min(value, 100)
      value when is_binary(value) -> value |> Integer.parse() |> parsed_limit()
      _ -> @default_limit
    end
  end

  defp parsed_limit({value, ""}) when value > 0, do: min(value, 100)
  defp parsed_limit(_value), do: @default_limit

  defp repo_path(owner, repo, suffix) do
    "/repos/#{URI.encode_www_form(owner)}/#{URI.encode_www_form(repo)}#{suffix}"
  end

  defp source_url(owner, repo), do: "https://github.com/#{owner}/#{repo}"

  defp endpoint(%Integration{base_url: base_url}, path) do
    String.trim_trailing(to_string(base_url), "/") <> path
  end

  defp headers(%Integration{token: token}) when is_binary(token) and token != "" do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end

  defp headers(_integration) do
    [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp first_line(nil), do: nil

  defp first_line(value) do
    value
    |> to_string()
    |> String.split("\n", parts: 2)
    |> List.first()
  end

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
