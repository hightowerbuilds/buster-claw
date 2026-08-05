defmodule BusterClaw.Agent.ChatTransport.Claude do
  @moduledoc """
  Chat transport for Claude Code.

  **Phase 1: one-shot.** `claude -p --output-format stream-json`, one process per
  turn, threaded with `--resume`. Byte-for-byte the argv `Chat.start_run/2` built
  inline before the extraction.

  ## What Phase 2 changes here, and why it is not one more flag

  Phase 0 measured the duplex path (`scripts/probe_claude_duplex.exs`): with
  `--input-format stream-json` the process stays alive, stdin stays open, and a
  JSONL user message written mid-turn is taken into that turn. Three things that
  are true today stop being true:

  1. **`result` becomes the turn boundary, not the process boundary.** The OS
     process survives and answers the next message on the same session.
  2. **`system/init` re-emits at the start of every turn** — same session id,
     same capability list. It is not a once-per-process event to latch onto.
  3. ⚠ **`total_cost_usd` is session-CUMULATIVE while `num_turns` is per-turn.**
     One process per turn is the only reason the field currently equals the
     turn's cost. Whatever reads it after Phase 2 must subtract the previous
     total, or every cost line silently becomes a running total — and the
     existing tests will not catch it, because they only ever assert turn one.

  The acceptance receipt is `--replay-user-messages`, which echoes our stdin back
  on stdout. Operator messages replay with `message.content` as a **string**;
  tool returns arrive as a **list of `tool_result` blocks**. That is the only
  discriminator, and both currently normalize to `:user`.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent), opts)}

  @impl true
  def capabilities do
    # Phase 1 is one-shot, so no steering is offered yet even though the harness
    # supports it. Phase 2 flips this to
    # `%{modes: [...:steer...], receipt: :boundary_replay}` — claiming it before
    # the duplex transport exists would be a UI that lies.
    %{modes: [:start_turn, :queue_next, :interrupt], receipt: :none}
  end

  @impl true
  def start_turn(handle, text) do
    ChatTransport.spawn_turn(handle, text, argv(handle))
  end

  @impl true
  def steer(_handle, _turn_ref, _text), do: {:error, :not_supported}

  @impl true
  def interrupt(handle, turn_ref) do
    if is_port(turn_ref), do: BusterClaw.AgentRunner.kill_port(turn_ref)
    {:ok, %{handle | port: nil}}
  end

  @impl true
  def close(handle) do
    if is_port(handle.port), do: BusterClaw.AgentRunner.kill_port(handle.port)
    :ok
  end

  # `--append-system-prompt` is claude's spelling and claude's alone; this is the
  # one backend that can take the conversation guide as a flag rather than
  # folding it into the prompt.
  defp argv(handle) do
    ChatTransport.stream_args(handle) ++
      resume_args(handle.session_id) ++
      append_args(handle.append_system_prompt) ++
      handle.extra_cli_args
  end

  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--resume", session_id]

  defp append_args(nil), do: []
  defp append_args(""), do: []
  defp append_args(prompt), do: ["--append-system-prompt", prompt]
end
