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
          :system | :assistant_text | :tool_use | :tool_result | :user | :result | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t() | nil,
          tool: String.t() | nil,
          tool_input: map() | nil,
          summary: String.t() | nil,
          session_id: String.t() | nil,
          cost_usd: number() | nil,
          num_turns: integer() | nil,
          raw: map()
        }

  defstruct kind: :unknown,
            text: nil,
            tool: nil,
            tool_input: nil,
            summary: nil,
            session_id: nil,
            cost_usd: nil,
            num_turns: nil,
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
  see `daily-growth/roadmaps/AGENT_BACKEND_ROADMAP.md` for the captured streams.
  Anything not observed becomes `:unknown` with `raw` intact rather than being
  guessed at: a wrong mapping is worse than an ignored event, because the
  consumer renders it.
  """
  @spec normalize(atom(), map()) :: t()
  def normalize(:codex, map), do: normalize_codex(map)
  def normalize(:opencode, map), do: normalize_opencode(map)
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
    do: %__MODULE__{kind: :result, raw: m}

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
      # The only harness of the three that reports what a run actually cost.
      cost_usd: part["cost"],
      session_id: m["sessionID"],
      raw: m
    }

  defp normalize_opencode(m), do: %__MODULE__{kind: :unknown, raw: m}

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
