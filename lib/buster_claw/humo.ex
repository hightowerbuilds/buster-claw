defmodule BusterClaw.Humo do
  @moduledoc """
  Humo — the shader-driven chat surface's own headless Claude (Phase 1,
  HUMO_ROADMAP.md).

  Deliberately **not** a new GenServer: `BusterClaw.Agent.Chat` is already a
  per-conversation harness (DynamicSupervisor + Registry, per-conv PubSub
  topics, per-conv transcripts, queue/interrupt/thinking/Sentinel audit), so
  Humo's "own headless Claude" is that same proven engine pinned to the
  reserved conversation id `"humo"`. Forking a parallel session GenServer
  would violate the roadmap's reuse rule (Cross-cutting §D).

  No `Conversations` row is created for `"humo"`: `Message.conv_id` is a plain
  string (no FK), so the transcript persists and PubSub works while the
  conversation stays out of the homepage chat tabs — Humo is a separate
  showcase surface, not another tab of the same chat.
  """

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Transcript

  @conv_id "humo"

  @doc "The reserved conversation id backing the Humo surface."
  def conv_id, do: @conv_id

  @doc "Subscribe the caller to Humo's chat events (`{:agent_chat, \"humo\", payload}`)."
  def subscribe, do: Chat.subscribe(@conv_id)

  @doc """
  Ensure Humo's chat process is running, started with the expression guide as its
  appended system prompt so the agent knows it can dress/draw into the smoke.
  Idempotent; a no-op once the process exists (the guide is fixed at start).
  """
  def ensure_started, do: Chat.ensure_started(@conv_id, append_system_prompt: expression_guide())

  @doc """
  Send a user message to Humo's Claude. Starts the process (taught the expression
  vocabulary) on demand, then queues if a turn is in flight.
  """
  def send_message(text) when is_binary(text) do
    with {:ok, _pid} <- ensure_started() do
      Chat.send_message(@conv_id, text)
    end
  end

  @doc "Interrupt Humo's in-flight turn (no-op when idle)."
  def interrupt, do: Chat.interrupt(@conv_id)

  @doc """
  Clear the Humo conversation: reset its Claude session (kill any in-flight run,
  forget context so the next message starts fresh) and wipe its persisted
  transcript. The surface clears via the `{:reset}` event `Chat.reset/1`
  broadcasts. Idempotent.
  """
  def clear do
    Chat.reset(@conv_id)
    Transcript.clear(@conv_id)
    :ok
  end

  @doc "Humo's run status: `:idle` or `:running`."
  def status, do: Chat.status(@conv_id)

  @doc "Whether Humo has a turn in flight."
  def running?, do: Chat.running?(@conv_id)

  @doc "Humo's persisted transcript, oldest-first."
  def recent(opts \\ []), do: Transcript.recent(@conv_id, opts)

  @doc """
  The expression vocabulary Humo's agent is taught (its appended system prompt).
  Kept compact — it rides every turn. Grows one line per expression mode as the
  library does (`humo-graph`, `humo-draw` next).
  """
  def expression_guide do
    """
    You are Humo. Your replies are rendered live in a drifting smoke shader, and \
    the reader can hover a lens to read any part crisply. You may set the visual \
    mood of your reply by including a fenced block ANYWHERE in your message; it is \
    stripped from the shown text, so it never appears to the reader.

    Format: ```humo-style {json}``` where json may set:
      energy  0..1   — 0 calm & slow, 1 urgent & turbulent
      temp    cool | neutral | warm (or a number -1..1) — cool reads ashen, warm embery
      density 0..1   — thin wisps .. thick smoke
      mode    "gameboy" — render this reply as retro pixelated Game Boy green

    Use it only when tone genuinely helps. Examples:
      An urgent warning: ```humo-style {"energy":0.9,"temp":"warm","density":0.8}```
      A calm explanation: ```humo-style {"energy":0.2,"temp":"cool"}```
      Something playful: ```humo-style {"mode":"gameboy"}```

    You can also render a DIAGRAM. Emit a block:
    ```humo-graph {"nodes":[{"id":"a","label":"Client"},{"id":"b","label":"Server"},{"id":"c","label":"DB"}],"edges":[["a","b"],["b","c"]]}```
    — it is stripped from the shown text and the graph condenses onto the screen,
    laid out left-to-right by dependency. Every node has an "id" and a "label";
    every edge is ["fromId","toId"]. Keep it under ~24 nodes. Use it when the
    structure — a flow, a dependency graph, a small architecture — reads clearer
    drawn than described.
    """
  end
end
