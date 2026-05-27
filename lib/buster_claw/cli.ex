defmodule BusterClaw.CLI do
  @moduledoc """
  Buster Claw CLI — thin HTTP client over the local command surface.

  ## Examples

      $ ./buster-claw commands
      $ ./buster-claw run source_list
      $ ./buster-claw source list
      $ ./buster-claw run source_create --json '{"url":"https://...","type":"rss"}'
      $ ./buster-claw source ingest --json '{"id": 1}'

  ## Configuration

  - `BUSTER_CLAW_URL` — base URL of the Buster Claw HTTP API. Default
    `http://127.0.0.1:4000`.
  - `BUSTER_CLAW_API_TOKEN` — token. If unset, falls back to reading
    `~/Library/Application Support/BusterClaw/api_token`.
  """

  @default_url "http://127.0.0.1:4000"

  @doc false
  def main(argv) do
    ensure_apps()
    {opts, args, _} = OptionParser.parse(argv, strict: switches(), aliases: aliases())

    case args do
      ["commands"] -> commands(opts)
      ["help"] -> usage()
      ["--help"] -> usage()
      ["run", name] -> run(name, opts)
      [noun, verb] -> run("#{noun}_#{verb}", opts)
      [name] -> run(name, opts)
      [] -> usage()
      _ -> die("too many positional arguments — use `./buster-claw help`", 2)
    end
  end

  defp switches do
    [json: :string, url: :string, token: :string, help: :boolean]
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

  defp run(name, opts) do
    args = parse_args(opts)
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

  # ---- HTTP ----

  defp http_get(path) do
    url = base_url() <> path

    case Req.get(url,
           headers: [{"accept", "application/json"} | auth_header()],
           receive_timeout: 5_000,
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

    headers =
      [{"accept", "application/json"}]
      |> maybe_add_auth(opts[:auth], opts[:opts])

    case Req.post(url, json: body, headers: headers, receive_timeout: 5_000, retry: false) do
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

  defp connection_message(reason), do: "request failed: #{inspect(reason)}"

  # ---- Token / URL ----

  defp token(opts) do
    cond do
      flag = Keyword.get(opts, :token) -> flag
      env = System.get_env("BUSTER_CLAW_API_TOKEN") -> env
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

    Options:
      --json '<json>'        Pass command args as a JSON object.
      --url <url>            Override BUSTER_CLAW_URL (default #{@default_url}).
      --token <token>        Override BUSTER_CLAW_API_TOKEN.
      -h, --help             Print this message.

    Examples:
      ./buster-claw commands
      ./buster-claw source list
      ./buster-claw run source_create --json '{"url":"https://x.io","type":"rss"}'
      ./buster-claw run analysis_queue --json '{"document_id": 1}'
    """)
  end

  defp die(message, code) do
    IO.puts(:stderr, "error: #{message}")
    System.halt(code)
  end
end
