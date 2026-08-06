defmodule BusterClaw.Agent.StreamEvent do
  @moduledoc """
  The shared parser for Claude's `--output-format stream-json` output.

  Headless Claude emits one JSON object per line (NDJSON). This module turns a
  raw byte stream into normalized `%StreamEvent{}` structs, and is the single
  source of truth for *interpreting* those events. The consumer is:

    * `BusterClaw.Agent.Chat` — broadcasts `:assistant_text` / `:tool_use` /
      `:result` events to a LiveView chat transcript, and threads the
      `:session_id` for `--resume`.

  The `activity_state/2` / `activity_label/1` helpers (an event → coarse
  activity classification) are also provided here and covered by tests.

  Everything here is pure and easy to test. Streaming I/O (the Port, buffering,
  PubSub) lives in the consumers.

  ## Event kinds

    * `:system`         — session init; carries `:session_id`
    * `:assistant_text` — the model talking / planning; carries `:text`
    * `:tool_use`       — a tool call; carries `:tool`, `:tool_input`, `:summary`
    * `:tool_result`    — a tool's result coming back
    * `:user`           — a user/tool-result turn echoed back
    * `:usage`          — token counts arriving separately from the result, as
                          codex's app-server reports them; carries `:usage`
    * `:result`         — the run finished; carries `:text`, `:cost_usd`,
                          `:num_turns`, `:session_id`
    * `:unknown`        — anything else (kept so callers can ignore it cleanly)
  """

  @reading ~w(Read Grep Glob LS NotebookRead WebFetch WebSearch)
  @writing ~w(Write Edit NotebookEdit)

  # The shell tool under each harness's own name. codex calls a shell command
  # `command_execution`; opencode calls it `bash`.
  @shell ~w(Bash bash command_execution)

  # Downcased, for harnesses that name the same jobs in lower case.
  @reading_any ~w(read grep glob ls list notebookread webfetch websearch fetch search)
  @writing_any ~w(write edit patch notebookedit apply_patch)

  @type kind ::
          :system
          | :assistant_text
          | :tool_use
          | :tool_result
          | :user
          | :usage
          | :result
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t() | nil,
          tool: String.t() | nil,
          tool_input: map() | nil,
          summary: String.t() | nil,
          session_id: String.t() | nil,
          cost_usd: number() | nil,
          num_turns: integer() | nil,
          usage: usage() | nil,
          raw: map()
        }

  @typedoc """
  Token counts normalized across the three harnesses. `cost_usd` is `nil`
  wherever the CLI does not state one — see `usage/2`.
  """
  @type usage :: %{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          cost_usd: number() | nil
        }

  defstruct kind: :unknown,
            text: nil,
            tool: nil,
            tool_input: nil,
            summary: nil,
            session_id: nil,
            cost_usd: nil,
            num_turns: nil,
            usage: nil,
            raw: %{}

  # --- byte stream → lines ---

  @doc """
  Split a buffer on newlines into `{complete_lines, remainder}`. The remainder
  is the trailing partial line (no newline yet) to prepend to the next chunk.
  """
  @spec split_lines(String.t()) :: {[String.t()], String.t()}
  def split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end

  @doc "Decode a single NDJSON line. `{:ok, map}` or `:error` for blank/garbage."
  @spec decode(String.t()) :: {:ok, map()} | :error
  def decode(line) do
    case line |> String.trim() |> Jason.decode() do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  @doc "Decode and normalize a line in one step. `{:ok, %StreamEvent{}}` or `:error`."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(line), do: parse(:claude, line)

  @doc """
  Decode and normalize a line emitted by `backend`.

  `nil` and any unrecognised backend are read as claude — every caller predates
  harness selection, and claude's schema is the one they were written against.
  """
  @spec parse(atom(), String.t()) :: {:ok, t()} | :error
  def parse(backend, line) do
    case decode(line) do
      {:ok, map} -> {:ok, normalize(backend, map)}
      :error -> :error
    end
  end

  @doc """
  Normalize a decoded event from `backend`.

  Each harness emits a different schema and each was **observed**, not assumed —
  see `daily-growth/archive/08-04-26-agent-backend-roadmap.md`
  for the captured streams.
  Anything not observed becomes `:unknown` with `raw` intact rather than being
  guessed at: a wrong mapping is worse than an ignored event, because the
  consumer renders it.
  """
  @spec normalize(atom(), map()) :: t()
  def normalize(:codex, map), do: normalize_codex(map)
  def normalize(:codex_app_server, map), do: normalize_codex_app_server(map)
  def normalize(:opencode, map), do: normalize_opencode(map)
  def normalize(:opencode_server, map), do: normalize_opencode_server(map)
  def normalize(_claude_or_unknown, map), do: normalize(map)

  # --- codex ---------------------------------------------------------------
  #
  # Observed (codex-cli 0.146.0, `exec --json`):
  #
  #   {"type":"thread.started","thread_id":"…"}
  #   {"type":"turn.started"}
  #   {"type":"item.started",  "item":{"type":"command_execution","command":…,"status":"in_progress"}}
  #   {"type":"item.completed","item":{"type":"agent_message","text":…}}
  #   {"type":"item.completed","item":{"type":"command_execution","aggregated_output":…,"exit_code":…}}
  #   {"type":"turn.completed","usage":{"input_tokens":…,"output_tokens":…}}
  #
  # Codex reports token usage but no dollar cost, so `cost_usd` stays nil rather
  # than being computed from a price table this app does not own.

  defp normalize_codex(%{"type" => "thread.started"} = m),
    do: %__MODULE__{kind: :system, session_id: m["thread_id"], raw: m}

  defp normalize_codex(%{"type" => "turn.completed"} = m),
    do: %__MODULE__{kind: :result, usage: codex_usage(m["usage"]), raw: m}

  defp normalize_codex(
         %{"type" => "item.completed", "item" => %{"type" => "agent_message"} = item} = m
       ),
       do: %__MODULE__{kind: :assistant_text, text: stringish(item["text"]), raw: m}

  defp normalize_codex(
         %{"type" => "item.started", "item" => %{"type" => "command_execution"} = item} = m
       ) do
    command = stringish(item["command"]) || ""

    %__MODULE__{
      kind: :tool_use,
      tool: "command_execution",
      tool_input: %{"command" => command},
      summary: "command_execution: " <> command,
      raw: m
    }
  end

  defp normalize_codex(
         %{"type" => "item.completed", "item" => %{"type" => "command_execution"}} = m
       ),
       do: %__MODULE__{kind: :tool_result, raw: m}

  defp normalize_codex(m), do: %__MODULE__{kind: :unknown, raw: m}

  # --- codex app-server ----------------------------------------------------
  #
  # A DIFFERENT schema from `codex exec --json` above, not a variant of it:
  # these are JSON-RPC notifications, so the discriminator is `method` and the
  # payload is under `params`. Observed against codex-cli 0.146.0 by
  # `scripts/probe_codex_appserver.exs`; the redacted trace is the reference.
  #
  #   {"method":"turn/started",   "params":{"threadId":…,"turn":{"id":…}}}
  #   {"method":"item/started",   "params":{"item":{"type":"commandExecution","command":…}}}
  #   {"method":"item/completed", "params":{"item":{"type":"agentMessage","text":…}}}
  #   {"method":"turn/completed", "params":{"threadId":…,"turn":{"status":…,"error":…}}}
  #   {"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":…,"total":…}}}
  #
  # `item.type` is camelCase here and snake_case in `exec` output — same
  # concepts, different spelling, which is exactly why these are separate
  # normalizers rather than one with a shared fallback.

  defp normalize_codex_app_server(%{"method" => "thread/started", "params" => params} = m),
    do: %__MODULE__{kind: :system, session_id: get_in(params, ["thread", "id"]), raw: m}

  defp normalize_codex_app_server(%{"method" => "turn/started", "params" => params} = m),
    do: %__MODULE__{kind: :system, session_id: params["threadId"], raw: m}

  # The model talking. Taken from `item/completed` rather than accumulated from
  # `item/agentMessage/delta`: the completed item carries the whole text, so
  # coalescing is by construction and the transcript is never handed one row per
  # token. The deltas fall through to `:unknown` on purpose.
  defp normalize_codex_app_server(
         %{
           "method" => "item/completed",
           "params" => %{"item" => %{"type" => "agentMessage"} = item}
         } =
           m
       ),
       do: %__MODULE__{kind: :assistant_text, text: stringish(item["text"]), raw: m}

  # A shell command, reported when it STARTS so the transcript shows work in
  # progress rather than only after it finishes — the same moment `exec`'s
  # `item.started` fires.
  defp normalize_codex_app_server(
         %{
           "method" => "item/started",
           "params" => %{"item" => %{"type" => "commandExecution"} = item}
         } = m
       ) do
    command = stringish(item["command"]) || ""

    %__MODULE__{
      kind: :tool_use,
      tool: "command_execution",
      tool_input: %{"command" => command},
      summary: "command_execution: " <> command,
      raw: m
    }
  end

  defp normalize_codex_app_server(
         %{
           "method" => "item/completed",
           "params" => %{"item" => %{"type" => "commandExecution"}}
         } = m
       ),
       do: %__MODULE__{kind: :tool_result, raw: m}

  # Our own message echoed back. `clientId` is the `clientUserMessageId` we sent,
  # which makes this the acceptance receipt for a steer — the one thing that
  # proves the harness took it. `:user` events are ignored by the transcript
  # (they would double the operator's own bubble), so this is carried for the
  # transport to read rather than for display.
  defp normalize_codex_app_server(
         %{"method" => "item/completed", "params" => %{"item" => %{"type" => "userMessage"}}} = m
       ),
       do: %__MODULE__{kind: :user, raw: m}

  defp normalize_codex_app_server(%{"method" => "turn/completed", "params" => params} = m) do
    turn = params["turn"] || %{}

    %__MODULE__{
      kind: :result,
      # Codex reports token counts but no dollar figure, and this app owns no
      # price table — a computed cost would be a number the operator trusts and
      # we invented.
      text: turn_error_text(turn["error"]),
      num_turns: 1,
      session_id: params["threadId"],
      raw: m
    }
  end

  defp normalize_codex_app_server(
         %{"method" => "thread/tokenUsage/updated", "params" => params} = m
       ),
       do: %__MODULE__{kind: :usage, usage: codex_app_server_usage(params["tokenUsage"]), raw: m}

  defp normalize_codex_app_server(m), do: %__MODULE__{kind: :unknown, raw: m}

  defp turn_error_text(%{"message" => message}) when is_binary(message), do: message
  defp turn_error_text(_error), do: nil

  # `last` is this turn; `total` is the thread. The turn is what a transcript
  # line is about, so `last` is the one normalized — the same per-turn-vs-session
  # distinction that made claude's cumulative cost a bug.
  defp codex_app_server_usage(%{"last" => last}) when is_map(last) do
    %{
      input_tokens: last["inputTokens"],
      output_tokens: last["outputTokens"],
      cache_read_tokens: last["cachedInputTokens"],
      cache_write_tokens: last["cacheWriteInputTokens"],
      cost_usd: nil
    }
  end

  defp codex_app_server_usage(_usage), do: nil

  # --- opencode ------------------------------------------------------------
  #
  # Observed (opencode 1.18.3, `run --format json`). Everything of interest is
  # nested under `part`, and `sessionID` rides on every event:
  #
  #   {"type":"step_start", "sessionID":…,"part":{"type":"step-start"}}
  #   {"type":"tool_use",   "sessionID":…,"part":{"type":"tool","tool":"read","state":{"status":…,"input":…}}}
  #   {"type":"text",       "sessionID":…,"part":{"type":"text","text":…}}
  #   {"type":"step_finish","sessionID":…,"part":{"type":"step-finish","reason":…,"tokens":…,"cost":…}}
  #
  # `step_finish` fires once per STEP, not once per run — `reason` is
  # "tool-calls" mid-run and "stop" at the end. Only the latter is a `:result`;
  # treating every step_finish as the end would close the transcript on the
  # first tool call.

  defp normalize_opencode(%{"type" => "step_start"} = m),
    do: %__MODULE__{kind: :system, session_id: m["sessionID"], raw: m}

  defp normalize_opencode(%{"type" => "text", "part" => %{"text" => text}} = m),
    do: %__MODULE__{
      kind: :assistant_text,
      text: stringish(text),
      session_id: m["sessionID"],
      raw: m
    }

  defp normalize_opencode(%{"type" => "tool_use", "part" => %{"tool" => tool} = part} = m) do
    input = get_in(part, ["state", "input"]) || %{}

    %__MODULE__{
      kind:
        if(get_in(part, ["state", "status"]) == "completed", do: :tool_result, else: :tool_use),
      tool: stringish(tool),
      tool_input: input,
      summary: tool_summary(stringish(tool) || "", input),
      session_id: m["sessionID"],
      raw: m
    }
  end

  defp normalize_opencode(%{"type" => "step_finish", "part" => %{"reason" => "stop"} = part} = m),
    do: %__MODULE__{
      kind: :result,
      cost_usd: part["cost"],
      usage: opencode_usage(part),
      session_id: m["sessionID"],
      raw: m
    }

  defp normalize_opencode(m), do: %__MODULE__{kind: :unknown, raw: m}

  # --- opencode server mode -------------------------------------------------
  #
  # A THIRD opencode shape, distinct from `run --format json` above: the v1
  # server's SSE stream. Observed by `scripts/probe_opencode_server.exs` against
  # opencode 1.18.3.
  #
  # `BusterClaw.Agent.OpenCodeServer` pre-chews two things this parser cannot
  # know on its own, and passes them in:
  #
  #   * `role` — SSE part events carry no role at all, only a `messageID`. The
  #     connection tracks which ids are the assistant's from `message.updated`.
  #   * `cost` on the idle event — opencode reports cost per STEP, so the
  #     connection sums them for the turn. Doing it here would need state, and
  #     this module is pure.

  defp normalize_opencode_server(%{"type" => "part", "role" => "assistant", "part" => part} = m) do
    case part do
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
        %__MODULE__{kind: :assistant_text, text: text, raw: m}

      %{"type" => "tool"} ->
        normalize_opencode_server_tool(part, m)

      %{"type" => "step-finish"} ->
        %__MODULE__{kind: :usage, usage: opencode_usage(part), raw: m}

      _ ->
        %__MODULE__{kind: :unknown, raw: m}
    end
  end

  # A part belonging to the USER is our own message echoed back. It is the
  # acceptance receipt, which the connection handles directly; the transcript
  # ignores it rather than doubling the operator's own bubble.
  defp normalize_opencode_server(%{"type" => "part"} = m),
    do: %__MODULE__{kind: :unknown, raw: m}

  # `session.idle` is the turn boundary — exactly one per run, including a run
  # that was steered mid-flight. That is what proved the steered message joined
  # the ACTIVE turn instead of starting a second one.
  defp normalize_opencode_server(%{"type" => "idle"} = m),
    do: %__MODULE__{kind: :result, cost_usd: m["cost"], num_turns: 1, raw: m}

  defp normalize_opencode_server(m), do: %__MODULE__{kind: :unknown, raw: m}

  defp normalize_opencode_server_tool(part, m) do
    input = get_in(part, ["state", "input"]) || %{}
    tool = stringish(part["tool"]) || ""

    %__MODULE__{
      kind:
        if(get_in(part, ["state", "status"]) == "completed", do: :tool_result, else: :tool_use),
      tool: tool,
      tool_input: input,
      summary: tool_summary(tool, input),
      raw: m
    }
  end

  # --- decoded map → normalized event ---

  @doc "Turn a decoded stream-json map into a normalized `%StreamEvent{}`."
  @spec normalize(map()) :: t()
  def normalize(%{"type" => "system"} = m),
    do: %__MODULE__{kind: :system, session_id: m["session_id"], raw: m}

  def normalize(%{"type" => "result"} = m),
    do: %__MODULE__{
      kind: :result,
      text: stringish(m["result"]),
      cost_usd: m["total_cost_usd"],
      num_turns: m["num_turns"],
      session_id: m["session_id"],
      usage: claude_usage(m),
      raw: m
    }

  def normalize(%{"type" => "user"} = m), do: %__MODULE__{kind: :user, raw: m}

  def normalize(%{"type" => "assistant", "message" => %{"content" => content}} = m)
      when is_list(content) do
    case Enum.find(content, &(&1["type"] == "tool_use")) do
      %{"name" => name} = tool ->
        input = tool["input"] || %{}

        %__MODULE__{
          kind: :tool_use,
          tool: name,
          tool_input: input,
          summary: tool_summary(name, input),
          raw: m
        }

      _ ->
        %__MODULE__{kind: :assistant_text, text: text_content(content), raw: m}
    end
  end

  def normalize(m), do: %__MODULE__{kind: :unknown, raw: m}

  defp text_content(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp tool_summary("Bash", %{"command" => cmd}) when is_binary(cmd), do: "Bash: " <> cmd
  defp tool_summary("bash", %{"command" => cmd}) when is_binary(cmd), do: "bash: " <> cmd
  defp tool_summary(name, _input), do: name

  defp stringish(s) when is_binary(s), do: s
  defp stringish(_), do: nil

  # --- usage ----------------------------------------------------------------
  #
  # Three shapes, all measured 08-03, normalized to one. Every field is optional
  # because each CLI omits a different one, and a missing count must read as
  # "not stated" rather than as zero.
  #
  #   claude   %{"input_tokens", "output_tokens",
  #              "cache_read_input_tokens", "cache_creation_input_tokens"}  + total_cost_usd
  #   codex    %{"input_tokens", "output_tokens",
  #              "cached_input_tokens", "cache_write_input_tokens"}         (no cost)
  #   opencode %{"input", "output", "cache" => %{"read", "write"}}          + cost
  #
  # **Codex's `cost_usd` stays nil and must not be computed.** Deriving dollars
  # from tokens needs a price table this app does not own and cannot keep
  # current; a number the operator reads as "what this cost" should come from the
  # CLI that billed it, or not appear.

  defp claude_usage(%{"usage" => %{} = u} = m) do
    %{
      input_tokens: u["input_tokens"],
      output_tokens: u["output_tokens"],
      cache_read_tokens: u["cache_read_input_tokens"],
      cache_write_tokens: u["cache_creation_input_tokens"],
      cost_usd: m["total_cost_usd"]
    }
  end

  defp claude_usage(_m), do: nil

  defp codex_usage(%{} = u) do
    %{
      input_tokens: u["input_tokens"],
      output_tokens: u["output_tokens"],
      cache_read_tokens: u["cached_input_tokens"],
      cache_write_tokens: u["cache_write_input_tokens"],
      cost_usd: nil
    }
  end

  defp codex_usage(_u), do: nil

  defp opencode_usage(%{"tokens" => %{} = t} = part) do
    cache = Map.get(t, "cache") || %{}

    %{
      input_tokens: t["input"],
      output_tokens: t["output"],
      cache_read_tokens: cache["read"],
      cache_write_tokens: cache["write"],
      cost_usd: part["cost"]
    }
  end

  defp opencode_usage(_part), do: nil

  @doc """
  The usage reported by a completed run's captured output, or `nil`.

  For the blocking `AgentRunner.run/2` surfaces, which hold the whole stream as
  one string rather than seeing events as they arrive. Scans for the LAST
  `:result` event, because opencode emits one `step_finish` per step and only the
  final one ends the run.
  """
  @spec run_usage(atom(), String.t()) :: usage() | nil
  def run_usage(backend, output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(nil, fn line, acc ->
      case parse(backend, line) do
        {:ok, %__MODULE__{kind: :result, usage: %{} = usage}} -> usage
        _ -> acc
      end
    end)
  end

  def run_usage(_backend, _output), do: nil

  # --- TUI-facing interpretation (the starfield states) ---

  @doc """
  Map a normalized event to a starfield activity state, given the previous one.
  Events that don't imply an activity return `prev` unchanged.

  States: `:booting | :waiting | :reading | :writing | :email | :done`.
  """
  @spec activity_state(t(), atom()) :: atom()
  def activity_state(%__MODULE__{kind: :system}, _prev), do: :booting
  def activity_state(%__MODULE__{kind: :result}, _prev), do: :done
  def activity_state(%__MODULE__{kind: :user}, _prev), do: :waiting

  def activity_state(%__MODULE__{kind: :tool_use, tool: tool, tool_input: input}, _prev),
    do: tool_state(tool, input)

  # A plain text turn is the model talking / planning.
  def activity_state(%__MODULE__{kind: :assistant_text}, :booting), do: :booting
  def activity_state(%__MODULE__{kind: :assistant_text}, _prev), do: :waiting

  def activity_state(%__MODULE__{}, prev), do: prev

  defp tool_state(name, _input) when name in @reading, do: :reading
  defp tool_state(name, _input) when name in @writing, do: :writing
  defp tool_state(name, input) when name in @shell, do: bash_state(command_of(input))

  # codex and opencode name the same jobs differently (`read` vs `Read`), so the
  # activity classification is done on a downcased name rather than duplicating
  # every list. An unrecognised tool stays `:reading` — the existing default.
  defp tool_state(name, _input) when is_binary(name) do
    downcased = String.downcase(name)

    cond do
      downcased in @reading_any -> :reading
      downcased in @writing_any -> :writing
      true -> :reading
    end
  end

  defp tool_state(_name, _input), do: :reading

  defp command_of(input) when is_map(input), do: to_string(input["command"] || "")
  defp command_of(_input), do: ""

  # Order matters: an outbound/irreversible command is "transmitting" even though
  # it mentions gmail; the mail-touching reads are "incoming".
  defp bash_state(cmd) do
    cond do
      cmd =~ ~r/gmail_send|gmail_draft|dispatch\s+(reply|done|block)|document_save|\btee\b|>>/i ->
        :writing

      cmd =~ ~r/gmail|mailman|\binbox\b|dispatch\s+(list|claim|show)/i ->
        :email

      true ->
        :reading
    end
  end

  @doc "A short human label for the activity behind an event (for a status line)."
  @spec activity_label(t()) :: String.t() | nil
  def activity_label(%__MODULE__{kind: :tool_use, tool: tool, tool_input: %{"command" => cmd}})
      when tool in @shell and is_binary(cmd),
      do: "$ " <> String.slice(cmd, 0, 38)

  def activity_label(%__MODULE__{kind: :tool_use, tool: name}), do: name
  def activity_label(%__MODULE__{kind: :assistant_text}), do: "thinking"

  def activity_label(%__MODULE__{kind: :result, text: r}) when is_binary(r),
    do: String.slice(r, 0, 40)

  def activity_label(%__MODULE__{}), do: nil
end
