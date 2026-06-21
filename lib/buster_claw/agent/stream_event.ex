defmodule BusterClaw.Agent.StreamEvent do
  @moduledoc """
  The shared parser for Claude's `--output-format stream-json` output.

  Headless Claude emits one JSON object per line (NDJSON). This module turns a
  raw byte stream into normalized `%StreamEvent{}` structs, and is the single
  source of truth for *interpreting* those events. Two consumers share it:

    * `BusterClaw.Autopilot.Tui` — maps events to starfield activity states
      (`activity_state/2`) and a one-line status label (`activity_label/1`).
    * `BusterClaw.Agent.Chat` — broadcasts `:assistant_text` / `:tool_use` /
      `:result` events to a LiveView chat transcript, and threads the
      `:session_id` for `--resume`.

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
  def parse(line) do
    case decode(line) do
      {:ok, map} -> {:ok, normalize(map)}
      :error -> :error
    end
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
  defp tool_state("Bash", input), do: bash_state(to_string(input["command"] || ""))
  defp tool_state(_name, _input), do: :reading

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
  def activity_label(%__MODULE__{kind: :tool_use, tool: "Bash", tool_input: %{"command" => cmd}})
      when is_binary(cmd),
      do: "$ " <> String.slice(cmd, 0, 38)

  def activity_label(%__MODULE__{kind: :tool_use, tool: name}), do: name
  def activity_label(%__MODULE__{kind: :assistant_text}), do: "thinking"

  def activity_label(%__MODULE__{kind: :result, text: r}) when is_binary(r),
    do: String.slice(r, 0, 40)

  def activity_label(%__MODULE__{}), do: nil
end
