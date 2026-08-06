defmodule BusterClaw.Agent.ChatMessageEncoder do
  @moduledoc """
  Encode one operator message as a line of Claude's streaming-input JSONL.

  Its own module because it is the single point where untrusted operator text
  becomes bytes on an agent's stdin, and that is worth being able to point at.

  ## Shape

  Measured against claude 2.1.222 with `--input-format stream-json`
  (`scripts/probe_claude_duplex.exs`):

      {"type":"user","message":{"role":"user","content":"…"}}

  `content` is a plain string. That matters beyond encoding: it is also how the
  **acceptance receipt** is told apart. With `--replay-user-messages`, claude
  echoes our messages back on stdout — operator messages come back with
  `content` as a string, while tool returns arrive with `content` as a list of
  `tool_result` blocks. Both normalize to `:user` today, so the string form is
  the only discriminator available.

  ## The byte cap

  A message is rejected **before** it reaches `Port.command/2` rather than
  after. An oversized write to a pipe is not a clean error: it can block the
  calling process or wedge the stream mid-line, and a half-written JSONL line
  desynchronises the harness's parser for the rest of the conversation. Failing
  the submission is recoverable; a corrupted stream is not.

  The limit is on the ENCODED line, not the raw text, because escaping can grow
  a string substantially — a message of mostly quotes or non-ASCII encodes far
  larger than it reads.
  """

  # Generous next to any realistic chat message and far below the point where a
  # pipe write becomes a problem.
  @max_bytes 512 * 1024

  @doc "The byte ceiling applied to an encoded line."
  def max_bytes, do: @max_bytes

  @doc """
  Encode `text` as one newline-terminated JSONL user message.

  Returns `{:ok, iodata}` or `{:error, {:too_large, bytes, limit}}`.
  """
  @spec encode_user(String.t()) ::
          {:ok, binary()} | {:error, {:too_large, pos_integer(), pos_integer()}}
  def encode_user(text) when is_binary(text) do
    line = Jason.encode!(%{"type" => "user", "message" => %{"role" => "user", "content" => text}})
    size = byte_size(line) + 1

    if size > @max_bytes do
      {:error, {:too_large, size, @max_bytes}}
    else
      {:ok, line <> "\n"}
    end
  end

  @doc """
  True when a replayed `:user` event is one of OUR messages coming back, rather
  than a tool result being echoed.

  This is the acceptance receipt. The discriminator is the `content` shape —
  string for an operator message, a list of blocks for a tool return — because
  claude provides no other marker distinguishing them.
  """
  @spec operator_replay?(map()) :: boolean()
  def operator_replay?(%{"message" => %{"content" => content}}) when is_binary(content), do: true
  def operator_replay?(_event), do: false
end
