defmodule BusterClaw.Agent.ChatTransport.Codex do
  @moduledoc """
  Chat transport for Codex CLI.

  **Phase 1: one-shot, and deliberately context-less.** `codex exec --json`, one
  process per turn, **no resume**. That is not an oversight: `codex exec resume
  <id>` is a SUBCOMMAND, which changes the argv shape rather than appending to
  it, and `AgentBackend.argv/3` does not model that. Appending a flag codex would
  reject is worse than starting fresh, so a codex chat currently forgets between
  turns.

  Codex also has no `--append-system-prompt`; it answers that flag with
  `unexpected argument` and exits 2. The conversation guide is therefore
  PREPENDED to the prompt instead — same instructions, carried where this harness
  can receive them.

  ## What Phase 3 changes here

  `codex exec` is the wrong surface for interactive chat, and Phase 0 confirmed
  the right one exists (`scripts/probe_codex_appserver.exs`). `codex app-server`
  speaks JSON-RPC over stdio with `thread/start`, `thread/resume`, `turn/start`,
  `turn/steer`, and `turn/interrupt`. Measured:

  * `turn/start` returns **as soon as the turn exists** (`{turn: {id, status:
    "inProgress"}}`) and the work streams as notifications — which is exactly
    what makes a running turn addressable.
  * `turn/steer` takes `expectedTurnId` and returns `{turnId}`. A wrong id while
    a turn is active, and any id after it finished, are both refused with
    `-32600`. **The completion race is guarded by the protocol**, so Buster Claw
    does not have to invent that guard.
  * `clientUserMessageId` is a native field on both calls — the dedup key comes
    free.

  Moving to app-server also closes the resume gap above: the thread id is durable
  and later turns append to the same thread.

  ⚠ App Server still starts the operator's MCP servers, exactly as `codex exec`
  does. It is not a widening, but it is not a narrowing either, and it remains
  the reason the money surfaces stay Claude-pinned.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent), opts)}

  @impl true
  def capabilities do
    %{modes: [:start_turn, :queue_next, :interrupt], receipt: :none, persistent: false}
  end

  @impl true
  def start_turn(handle, text) do
    # `extra_cli_args` is carried even though it is currently unreachable here —
    # `Chat.effective_agent/1` pins any conversation that has them to claude,
    # because they ARE claude flags. Dropping them silently would turn that
    # deliberate pin into a quiet mis-run if the pin ever moves.
    argv = ChatTransport.stream_args(handle) ++ handle.extra_cli_args
    ChatTransport.spawn_turn(handle, prompt(handle, text), argv)
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

  # No resume args on purpose — see the moduledoc.
  defp prompt(%{append_system_prompt: nil}, text), do: text
  defp prompt(%{append_system_prompt: ""}, text), do: text
  defp prompt(%{append_system_prompt: guide}, text), do: guide <> "\n\n---\n\n" <> text
end
