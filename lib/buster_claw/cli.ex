defmodule BusterClaw.CLI do
  @moduledoc """
  Buster Claw CLI — thin HTTP client over the local command surface.

  ## Examples

      $ ./buster-claw commands
      $ ./buster-claw run runtime_status
      $ ./buster-claw document list
      $ ./buster-claw run web_search --json '{"query":"phoenix liveview"}'
      $ ./buster-claw run document_save --json '{"name":"Note","body":"# Note"}'

  ## Configuration

  - `BUSTER_CLAW_URL` — base URL of the Buster Claw HTTP API. Default
    `http://127.0.0.1:4000`.
  - `BUSTER_CLAW_API_TOKEN` — token. If unset, falls back to reading
    the configured app token, then
    `~/Library/Application Support/BusterClaw/api_token`.
  """

  @default_url "http://127.0.0.1:4000"
  @default_receive_timeout_ms 5_000
  @mailman_receive_timeout_ms 300_000

  @doc false
  def main(argv) do
    ensure_apps()
    {opts, args, _} = OptionParser.parse(argv, strict: switches(), aliases: aliases())

    case args do
      ["commands"] -> commands(opts)
      ["help"] -> usage()
      ["--help"] -> usage()
      ["terminal", "open"] -> terminal_open(opts)
      ["terminal", "open", role] -> terminal_open(opts, role)
      ["mailman", "poll"] -> mailman_poll(opts)
      ["dispatch", "list"] -> dispatch_list_cmd(opts)
      ["dispatch", "show", id] -> dispatch_show_cmd(id, opts)
      ["dispatch", "claim"] -> dispatch_claim_cmd(opts)
      ["dispatch", "done", id] -> dispatch_finish_cmd("dispatch_done", id, opts)
      ["dispatch", "block", id] -> dispatch_finish_cmd("dispatch_block", id, opts)
      ["dispatch", "reply", id] -> dispatch_reply_cmd(id, opts)
      ["jobs", "list"] -> dispatch_request("job_list", %{}, opts, &format_job_list/1)
      ["jobs", "show", key] -> dispatch_request("job_show", %{"key" => key}, opts, &format_job/1)
      ["run", name] -> run(name, opts)
      [noun, verb] -> run("#{noun}_#{verb}", opts)
      [name] -> run(name, opts)
      [] -> usage()
      _ -> die("too many positional arguments — use `./buster-claw help`", 2)
    end
  end

  defp switches do
    [
      json: :string,
      url: :string,
      token: :string,
      role: :string,
      label: :string,
      agent: :string,
      purpose: :string,
      session: :string,
      startup_profile: :string,
      account: :string,
      account_id: :string,
      email: :string,
      query: :string,
      limit: :integer,
      interval: :integer,
      timeout: :integer,
      max_runs: :integer,
      once: :boolean,
      no_activate: :boolean,
      verbose: :boolean,
      status: :string,
      note: :string,
      body: :string,
      job: :string,
      help: :boolean
    ]
  end

  defp aliases do
    [h: :help]
  end

  defp ensure_apps do
    Application.ensure_all_started(:req)
  end

  # ---- Subcommands ----

  defp commands(_opts) do
    case http_get("/api/commands") do
      {:ok, %{"commands" => list}} ->
        Enum.each(list, fn cmd ->
          IO.puts("#{pad(cmd["name"], 32)} #{cmd["description"]}")
        end)

      {:ok, other} ->
        IO.puts(pretty(other))

      {:error, reason} ->
        die(reason, 1)
    end
  end

  defp terminal_open(opts, positional_role \\ nil) do
    args =
      opts
      |> parse_args()
      |> maybe_put("role_key", Keyword.get(opts, :role) || positional_role)
      |> maybe_put("label", Keyword.get(opts, :label))
      |> maybe_put("agent_name", Keyword.get(opts, :agent))
      |> maybe_put("purpose", Keyword.get(opts, :purpose))
      |> maybe_put("session_key", Keyword.get(opts, :session))
      |> maybe_put("startup_profile", Keyword.get(opts, :startup_profile))
      |> maybe_put("activate", if(Keyword.get(opts, :no_activate), do: false, else: nil))

    run("terminal_tab_open", opts, args)
  end

  defp mailman_poll(opts) do
    args =
      opts
      |> parse_args()
      |> maybe_put("account_id", Keyword.get(opts, :account_id) || Keyword.get(opts, :account))
      |> maybe_put("email", Keyword.get(opts, :email))
      |> maybe_put("query", Keyword.get(opts, :query))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    interval = max(Keyword.get(opts, :interval, 60), 1)
    max_runs = if Keyword.get(opts, :once), do: 1, else: Keyword.get(opts, :max_runs)

    IO.puts("Mailman polling Gmail through Buster Claw every #{interval}s.")
    poll_gmail(args, opts, interval, max_runs, 1)
  end

  defp run(name, opts, args \\ nil) do
    args = args || parse_args(opts)
    body = %{"command" => name, "args" => args}

    case http_post("/api/run", body, auth: true, opts: opts) do
      {:ok, %{"ok" => true, "result" => result}} ->
        IO.puts(pretty(result))

      {:ok, %{"ok" => false, "error" => error} = payload} ->
        IO.puts(:stderr, "error: #{error}")
        if errors = payload["errors"], do: IO.puts(:stderr, pretty(errors))
        System.halt(1)

      {:error, reason} ->
        die(reason, 1)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp poll_gmail(args, opts, interval, max_runs, run_number) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    IO.puts("[#{stamp}] Mailman sync ##{run_number}")

    case http_post("/api/run", %{"command" => "gmail_sync", "args" => args},
           auth: true,
           opts: opts,
           receive_timeout: request_timeout_ms(opts, @mailman_receive_timeout_ms)
         ) do
      {:ok, %{"ok" => true, "result" => result}} ->
        IO.puts(mailman_result_output(result, opts))

      {:ok, %{"ok" => false, "error" => error} = payload} ->
        IO.puts(:stderr, "error: #{error}")
        if errors = payload["errors"], do: IO.puts(:stderr, pretty(errors))

      {:error, reason} ->
        IO.puts(:stderr, "error: #{reason}")
    end

    if max_runs && run_number >= max_runs do
      :ok
    else
      Process.sleep(interval * 1_000)
      poll_gmail(args, opts, interval, max_runs, run_number + 1)
    end
  end

  defp parse_args(opts) do
    case Keyword.get(opts, :json) do
      nil ->
        %{}

      raw ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> map
          {:ok, _} -> die("--json must be a JSON object", 2)
          {:error, _} -> die("invalid JSON in --json", 2)
        end
    end
  end

  # ---- Dispatch queue ----

  defp dispatch_list_cmd(opts) do
    args =
      %{}
      |> maybe_put("status", Keyword.get(opts, :status))
      |> maybe_put("job", Keyword.get(opts, :job))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    dispatch_request("dispatch_list", args, opts, &format_dispatch_list/1)
  end

  defp dispatch_show_cmd(id, opts) do
    dispatch_request("dispatch_show", %{"id" => id}, opts, &format_dispatch_item/1)
  end

  defp dispatch_claim_cmd(opts) do
    args =
      %{}
      |> maybe_put("job", Keyword.get(opts, :job))
      |> maybe_put("claimed_by", Keyword.get(opts, :session) || Keyword.get(opts, :job))

    dispatch_request("dispatch_claim", args, opts, &format_dispatch_claim/1)
  end

  defp dispatch_finish_cmd(command, id, opts) do
    args = maybe_put(%{"id" => id}, "note", Keyword.get(opts, :note))
    dispatch_request(command, args, opts, &format_dispatch_finish/1)
  end

  defp dispatch_reply_cmd(id, opts) do
    args =
      %{"id" => id}
      |> maybe_put("body", Keyword.get(opts, :body))
      |> maybe_put("email", Keyword.get(opts, :email))
      |> maybe_put("account_id", Keyword.get(opts, :account_id))

    dispatch_request("dispatch_reply", args, opts, &format_dispatch_reply/1)
  end

  defp dispatch_request(command, args, opts, formatter) do
    case http_post("/api/run", %{"command" => command, "args" => args}, auth: true, opts: opts) do
      {:ok, %{"ok" => true, "result" => result}} ->
        IO.puts(if Keyword.get(opts, :verbose), do: pretty(result), else: formatter.(result))

      {:ok, %{"ok" => false, "error" => error} = payload} ->
        IO.puts(:stderr, "error: #{error}")
        if errors = payload["errors"], do: IO.puts(:stderr, pretty(errors))
        System.halt(1)

      {:error, reason} ->
        die(reason, 1)
    end
  end

  @doc false
  def format_dispatch_list(items) when is_list(items) do
    case items do
      [] ->
        "No open Dispatch items."

      _ ->
        "#{length(items)} Dispatch #{plural(length(items), "item")}:\n" <>
          Enum.map_join(items, "\n", &dispatch_line/1)
    end
  end

  def format_dispatch_list(other), do: pretty(other)

  @doc false
  def format_dispatch_item(%{"empty" => true}), do: "Queue empty — nothing to claim."

  def format_dispatch_item(item) when is_map(item) do
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

  def format_dispatch_item(other), do: pretty(other)

  @doc false
  def format_dispatch_claim(%{"empty" => true}), do: "Queue empty — nothing to claim."

  def format_dispatch_claim(item) when is_map(item),
    do: "Claimed:\n" <> format_dispatch_item(item)

  def format_dispatch_claim(other), do: pretty(other)

  @doc false
  def format_dispatch_finish(item) when is_map(item),
    do: "Marked ##{item["id"]} #{item["status"]}."

  def format_dispatch_finish(other), do: pretty(other)

  @doc false
  def format_dispatch_reply(%{"dispatch_item_id" => id} = result) do
    "Replied to #{result["to"]} and closed item ##{id} (thread #{result["thread_id"] || "?"})."
  end

  def format_dispatch_reply(other), do: pretty(other)

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

  @doc false
  def format_job_list(jobs) when is_list(jobs) do
    case jobs do
      [] ->
        "No jobs defined. Drop a `<key>.md` in job-descriptions/."

      _ ->
        "#{length(jobs)} #{plural(length(jobs), "job")}:\n" <>
          Enum.map_join(jobs, "\n", fn job ->
            "  #{job["key"]} — #{job["name"]}#{job_summary_suffix(job["summary"])}"
          end)
    end
  end

  def format_job_list(other), do: pretty(other)

  @doc false
  def format_job(job) when is_map(job) do
    header = "#{job["name"]} (#{job["key"]})"
    summary = if blank?(job["summary"]), do: [], else: ["", job["summary"]]
    body = if blank?(job["body"]), do: [], else: ["", job["body"]]
    Enum.join([header] ++ summary ++ body, "\n")
  end

  def format_job(other), do: pretty(other)

  defp job_summary_suffix(summary) do
    if blank?(summary), do: "", else: " · #{summary}"
  end

  # ---- HTTP ----

  @doc false
  def request_timeout_ms(opts, default_ms \\ @default_receive_timeout_ms) do
    case Keyword.get(opts, :timeout) do
      seconds when is_integer(seconds) -> max(seconds, 1) * 1_000
      _ -> default_ms
    end
  end

  @doc false
  def format_mailman_result(result) when is_map(result) do
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

  def format_mailman_result(result), do: pretty(result)

  defp http_get(path) do
    url = base_url() <> path

    case Req.get(url,
           headers: [{"accept", "application/json"} | auth_header()],
           receive_timeout: @default_receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} ->
        decode_response(status, body)

      {:error, reason} ->
        {:error, connection_message(reason)}
    end
  end

  defp http_post(path, body, opts) do
    url = base_url(opts[:opts]) <> path
    receive_timeout = Keyword.get(opts, :receive_timeout, request_timeout_ms(opts[:opts] || []))

    headers =
      [{"accept", "application/json"}]
      |> maybe_add_auth(opts[:auth], opts[:opts])

    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: receive_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: response_body}} ->
        decode_response(status, response_body)

      {:error, reason} ->
        {:error, connection_message(reason)}
    end
  end

  defp maybe_add_auth(headers, true, opts) do
    headers ++ auth_header(opts)
  end

  defp maybe_add_auth(headers, _, _), do: headers

  defp auth_header(opts \\ []) do
    case token(opts) do
      nil -> []
      tok -> [{"authorization", "Bearer " <> tok}]
    end
  end

  defp decode_response(_status, body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_response(status, body) do
    body = IO.iodata_to_binary(body)

    case Jason.decode(body) do
      {:ok, parsed} when status in 200..299 -> {:ok, parsed}
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, "HTTP #{status}: #{body}"}
    end
  end

  defp connection_message({:failed_connect, _}) do
    "could not connect to Buster Claw at #{base_url()} — is `mix phx.server` running?"
  end

  defp connection_message(%Req.TransportError{reason: :timeout}) do
    "request timed out while waiting for Buster Claw; try a larger --timeout <seconds> for long-running commands"
  end

  defp connection_message(reason), do: "request failed: #{inspect(reason)}"

  # ---- Token / URL ----

  defp token(opts) do
    cond do
      flag = Keyword.get(opts, :token) -> flag
      env = System.get_env("BUSTER_CLAW_API_TOKEN") -> env
      configured = Application.get_env(:buster_claw, :api_token) -> configured
      true -> read_token_file()
    end
  end

  defp read_token_file do
    path =
      case :os.type() do
        {:unix, :darwin} -> Path.expand("~/Library/Application Support/BusterClaw/api_token")
        _ -> Path.expand("~/.buster_claw/api_token")
      end

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> nil
    end
  end

  defp base_url(opts \\ []) do
    cond do
      flag = Keyword.get(opts || [], :url) -> flag
      env = System.get_env("BUSTER_CLAW_URL") -> env
      true -> @default_url
    end
  end

  # ---- Output / errors ----

  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp mailman_result_output(result, opts) do
    if Keyword.get(opts, :verbose), do: pretty(result), else: format_mailman_result(result)
  end

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

  defp pad(str, width) do
    String.pad_trailing(str, width)
  end

  defp usage do
    IO.puts("""
    Usage: ./buster-claw <subcommand> [options]

    Subcommands:
      commands               List the full command catalog.
      run <name> [opts]      Invoke a command by name.
      <noun> <verb> [opts]   Shorthand for `run <noun>_<verb>`.
      terminal open [role]   Open a role-labeled terminal tab inside Buster Claw.
      mailman poll           Continuously sync Gmail through the local API.
      dispatch list          List open queue items (--status, --job, --limit).
      dispatch show <id>     Show one queue item.
      dispatch claim         Claim the next open item (--job to scope, --session).
      dispatch done <id>     Mark an item done (--note).
      dispatch block <id>    Mark an item blocked (--note).
      jobs list              List the defined jobs (role roster).
      jobs show <key>        Read one job description.

    Options:
      --json '<json>'        Pass command args as a JSON object.
      --role <role>          Role key for `terminal open`.
      --label <label>        Visible label for `terminal open`.
      --agent <name>         Agent name metadata for `terminal open`.
      --purpose <text>       Purpose metadata for `terminal open`.
      --session <key>        Explicit terminal session key for `terminal open`.
      --startup-profile <p>  Known terminal startup profile; currently: mailman.
      --account-id <id>      Google account id for `mailman poll`.
      --email <email>        Google account email for `mailman poll`.
      --query <query>        Gmail query for `mailman poll`.
      --limit <n>            Gmail sync limit for `mailman poll`.
      --interval <seconds>   Poll interval for `mailman poll` (default 60).
      --timeout <seconds>    HTTP receive timeout (mailman default 300).
      --max-runs <n>         Stop `mailman poll` after n sync attempts.
      --once                 Run `mailman poll` once.
      --status <status>      Filter `dispatch list` (e.g. queued, claimed).
      --job <key>            Scope `dispatch list` / `dispatch claim` to a job.
      --note <text>          Note for `dispatch done` / `dispatch block`.
      --no-activate          Queue the tab without navigating to it.
      --verbose              Print full JSON for `mailman poll`.
      --url <url>            Override BUSTER_CLAW_URL (default #{@default_url}).
      --token <token>        Override BUSTER_CLAW_API_TOKEN.
      -h, --help             Print this message.

    Examples:
      ./buster-claw commands
      ./buster-claw document list
      ./buster-claw run web_search --json '{"query":"phoenix liveview"}'
      ./buster-claw run document_save --json '{"name":"Note","body":"# Note"}'
      ./buster-claw terminal open --role mailman --label Mailman
      ./buster-claw mailman poll --interval 60
    """)
  end

  defp die(message, code) do
    IO.puts(:stderr, "error: #{message}")
    System.halt(code)
  end
end
