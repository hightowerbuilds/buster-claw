defmodule BusterClaw.CLI.Format do
  @moduledoc """
  What the CLI prints: every result-to-terminal-text rendering, in one module
  with a public interface, separate from the HTTP client that fetches the
  results.

  Extracted from `BusterClaw.CLI` on 10-16 (CODE_QUALITY_SWEEP_10-16-26 Phase
  3, D3). These were ten `@doc false` publics inside a 960-line module — public
  so `cli_test.exs` could reach them, invisible as an interface to anyone else.
  Here they are the interface. `pretty/1` is the JSON fallback every renderer
  uses when a result has a shape it does not know.
  """

  def on_duty(result) when is_map(result) do
    job = result["job_name"] || result["job_key"] || "lookout"
    id = result["shift_id"]

    """
    On duty#{if id, do: " (shift ##{id})", else: ""} — #{job}, unattended.
    Trusted-sender mail is worked end to end: the agent reads each request, does
    the work with Buster Claw's command surface, and replies in-thread.
    Polling Gmail below. Ctrl-C stops the polling only — the shift keeps
    running. Run `./buster-claw off-duty` to stand down.
    """
    |> String.trim_trailing()
  end

  def on_duty(result), do: pretty(result)

  def off_duty(%{"shift_id" => id}), do: "Off duty — shift ##{id} stopped."
  def off_duty(result), do: pretty(result)

  def off_duty_error(error) do
    if is_binary(error) and String.contains?(error, "no_active_shift") do
      "Already off duty — no active shift."
    else
      "error: #{error}"
    end
  end

  def dispatch_list(items) when is_list(items) do
    case items do
      [] ->
        "No open Dispatch items."

      _ ->
        "#{length(items)} Dispatch #{plural(length(items), "item")}:\n" <>
          Enum.map_join(items, "\n", &dispatch_line/1)
    end
  end

  def dispatch_list(other), do: pretty(other)

  def dispatch_item(%{"empty" => true}), do: "Queue empty — nothing to claim."

  def dispatch_item(item) when is_map(item) do
    [
      "##{item["id"]} [#{item["status"]}] #{item["subject"] || "(no subject)"}",
      dispatch_kv("Source", item["source"]),
      dispatch_kv("Sender", item["sender"]),
      dispatch_kv("Job", item["recommended_role_key"]),
      dispatch_kv("Summary", item["request_summary"])
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def dispatch_item(other), do: pretty(other)

  def dispatch_claim(%{"empty" => true}), do: "Queue empty — nothing to claim."

  def dispatch_claim(item) when is_map(item),
    do: "Claimed:\n" <> dispatch_item(item)

  def dispatch_claim(other), do: pretty(other)

  def dispatch_finish(item) when is_map(item),
    do: "Marked ##{item["id"]} #{item["status"]}."

  def dispatch_finish(other), do: pretty(other)

  def dispatch_enqueue(item) when is_map(item),
    do:
      "Queued ##{item["id"]} (#{item["strategy"]}): #{item["request_summary"] || item["subject"]}"

  def dispatch_enqueue(other), do: pretty(other)

  def dispatch_reply(%{"dispatch_item_id" => id} = result) do
    "Replied to #{result["to"]} and closed item ##{id} (thread #{result["thread_id"] || "?"})."
  end

  def dispatch_reply(other), do: pretty(other)

  defp dispatch_line(item) do
    suffix =
      [item["sender"], item["recommended_role_key"]]
      |> Enum.reject(&blank?/1)
      |> case do
        [] -> ""
        parts -> " — " <> Enum.join(parts, " · ")
      end

    "  ##{item["id"]} [#{item["status"]}] #{item["subject"] || "(no subject)"}#{suffix}"
  end

  defp dispatch_kv(_label, value) when value in [nil, ""], do: nil
  defp dispatch_kv(label, value), do: "  #{label}: #{value}"

  # ---- Jobs ----

  def job_list(jobs) when is_list(jobs) do
    case jobs do
      [] ->
        "No jobs defined. Drop a `<key>.md` in jobs/."

      _ ->
        "#{length(jobs)} #{plural(length(jobs), "job")}:\n" <>
          Enum.map_join(jobs, "\n", fn job ->
            "  #{job["key"]} — #{job["name"]}#{job_summary_suffix(job["summary"])}"
          end)
    end
  end

  def job_list(other), do: pretty(other)

  def job(job) when is_map(job) do
    header = "#{job["name"]} (#{job["key"]})"
    summary = if blank?(job["summary"]), do: [], else: ["", job["summary"]]
    body = if blank?(job["body"]), do: [], else: ["", job["body"]]
    Enum.join([header] ++ summary ++ body, "\n")
  end

  def job(other), do: pretty(other)

  defp job_summary_suffix(summary) do
    if blank?(summary), do: "", else: " · #{summary}"
  end

  def mailman_result(result) when is_map(result) do
    documents = list_value(result, "documents")
    errors = list_value(result, "errors")
    account = map_value(result, "account")
    synced = value(result, "synced") || length(documents)
    requested = value(result, "requested")
    query = value(result, "query")
    estimate = value(result, "result_size_estimate")
    email = value(account, "email")
    last_synced_at = value(result, "last_synced_at")

    [
      mailman_summary_line(synced, requested, email),
      optional_line("Query", query),
      optional_line("Mailbox matches", estimate),
      optional_line("Last synced", last_synced_at),
      format_mailman_documents(documents),
      format_mailman_errors(errors)
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def mailman_result(result), do: pretty(result)

  def pretty(value), do: Jason.encode!(value, pretty: true)

  defp mailman_summary_line(0, requested, email) do
    suffix = requested_suffix(requested) <> account_suffix(email)
    "No new Gmail messages synced#{suffix}."
  end

  defp mailman_summary_line(synced, requested, email) do
    suffix = requested_suffix(requested) <> account_suffix(email)
    "Synced #{synced} Gmail #{plural(synced, "message")}#{suffix}."
  end

  defp requested_suffix(nil), do: ""
  defp requested_suffix(requested), do: " (requested #{requested})"

  defp account_suffix(nil), do: ""
  defp account_suffix(""), do: ""
  defp account_suffix(email), do: " for #{email}"

  defp optional_line(_label, nil), do: nil
  defp optional_line(_label, ""), do: nil
  defp optional_line(label, value), do: "#{label}: #{value}"

  defp format_mailman_documents([]), do: "Documents: none"

  defp format_mailman_documents(documents) do
    visible = Enum.take(documents, 5)
    hidden = max(length(documents) - length(visible), 0)

    lines =
      Enum.flat_map(visible, fn document ->
        title = value(document, "name") || value(document, "filename") || "Untitled Gmail message"
        date = value(document, "date")
        path = value(document, "artifact_path")

        [
          "  - #{title}#{date_suffix(date)}",
          if(path in [nil, ""], do: nil, else: "    #{path}")
        ]
      end)

    ["Documents:" | lines ++ more_documents_line(hidden)]
  end

  defp more_documents_line(0), do: []
  defp more_documents_line(count), do: ["  - ...and #{count} more"]

  defp format_mailman_errors([]), do: nil

  defp format_mailman_errors(errors) do
    ["Errors:" | Enum.map(errors, &"  - #{format_error_line(&1)}")]
  end

  defp format_error_line(error) when is_binary(error), do: error
  defp format_error_line(error), do: inspect(error)

  defp date_suffix(nil), do: ""
  defp date_suffix(""), do: ""
  defp date_suffix(date), do: " (#{date})"

  defp plural(1, singular), do: singular
  defp plural(_count, singular), do: singular <> "s"

  defp list_value(map, key) do
    case value(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp value(_map, _key), do: nil

  defp atom_key("account"), do: :account
  defp atom_key("artifact_path"), do: :artifact_path
  defp atom_key("date"), do: :date
  defp atom_key("documents"), do: :documents
  defp atom_key("email"), do: :email
  defp atom_key("errors"), do: :errors
  defp atom_key("filename"), do: :filename
  defp atom_key("last_synced_at"), do: :last_synced_at
  defp atom_key("name"), do: :name
  defp atom_key("query"), do: :query
  defp atom_key("requested"), do: :requested
  defp atom_key("result_size_estimate"), do: :result_size_estimate
  defp atom_key("synced"), do: :synced

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
