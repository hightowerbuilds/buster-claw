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

  @doc "Send a user message to Humo's Claude. Queues if a turn is in flight."
  def send_message(text) when is_binary(text), do: Chat.send_message(@conv_id, text)

  @doc "Interrupt Humo's in-flight turn (no-op when idle)."
  def interrupt, do: Chat.interrupt(@conv_id)

  @doc "Humo's run status: `:idle` or `:running`."
  def status, do: Chat.status(@conv_id)

  @doc "Whether Humo has a turn in flight."
  def running?, do: Chat.running?(@conv_id)

  @doc "Humo's persisted transcript, oldest-first."
  def recent(opts \\ []), do: Transcript.recent(@conv_id, opts)
end
