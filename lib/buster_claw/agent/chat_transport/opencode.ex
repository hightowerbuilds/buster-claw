defmodule BusterClaw.Agent.ChatTransport.OpenCode do
  @moduledoc """
  Chat transport for OpenCode.

  **Phase 1: one-shot.** `opencode run --format json --session <id>`, one process
  per turn. Like codex, OpenCode has no `--append-system-prompt`, so the
  conversation guide is PREPENDED to the prompt.

  ## What Phase 4 changes here

  Phase 0 (`scripts/probe_opencode_server.exs`) measured `opencode serve` and
  returned two findings that between them decide the whole design:

  1. **It steers.** A prompt submitted while the session was busy redirected the
     *active* run — step 1 finished, the redirect ran, steps 2 and 3 never did,
     and there was exactly one `session.idle` at the end. So OpenCode advertises
     `:steer`. The `:interrupt_then_resume` fallback the roadmap held in reserve
     is not needed.

  2. ⚠ **Confinement fails open and the API will not tell you.** A session
     created with a nonexistent `agent` is accepted, echoes the bogus name back
     on create *and* on re-fetch, and then admits a prompt. The server is
     strictly worse than the CLI here: `opencode run` at least prints the
     fallback line on stderr that `AgentBackend.fallback_warning?/2` scrapes.
     **Confined OpenCode chat therefore stays disabled** rather than failing
     open. General chat is unaffected.

  Two more facts worth carrying into the implementation:

  * **Two API generations are live, and the good one does not run.** v2
    (`/api/session/…`) natively models `delivery: "steer" | "queue"` and returns
    a receipt echoing the *effective* mode — the exact vocabulary this roadmap
    invented independently. But a v2 session parks the prompt in a
    `session.next.*` buffer and never executes it; it wants a driver we are not.
    v1 `/session/{id}/prompt_async` is the only path that runs. Re-check v2 on
    each upgrade: when it self-drives, it is strictly the better target.
  * **v1 returns an EMPTY body — no receipt at all.** Acceptance must be derived
    from the SSE `message.updated` that follows ~20ms later, never from the HTTP
    call. Hence `receipt: :admission_event` rather than anything stronger.

  Auth is Basic with the username literally `opencode`; the password comes from
  `OPENCODE_SERVER_PASSWORD` in the environment, never argv.
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
    argv =
      ChatTransport.stream_args(handle) ++ resume_args(handle.session_id) ++ handle.extra_cli_args

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

  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--session", session_id]

  defp prompt(%{append_system_prompt: nil}, text), do: text
  defp prompt(%{append_system_prompt: ""}, text), do: text
  defp prompt(%{append_system_prompt: guide}, text), do: guide <> "\n\n---\n\n" <> text
end
