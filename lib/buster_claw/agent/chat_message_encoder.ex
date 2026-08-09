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

  ## Attachments make `content` an array — and only then

  `content` is also allowed to be an *array of blocks*, which is how an image
  reaches the model with no file on disk (measured in Phase 0 on claude 2.1.220:
  answered correctly, no Read tool call, nothing written anywhere):

      {"type":"user","message":{"role":"user","content":[
        {"type":"text","text":"…"},
        {"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}
      ]}}

  **With no attachments the wire format does not change at all** — `content` stays
  a bare string. That is deliberate on two counts: it keeps the overwhelmingly
  common case byte-identical to what has shipped since duplex landed, and it
  keeps the array form meaningful as a signal rather than noise.

  It also means the acceptance receipt needs a second discriminator, because an
  operator message with an attachment and a tool return now both arrive as
  arrays. `operator_replay?/1` tells them apart by the *first* block: ours always
  leads with the operator's `text`, a tool return is `tool_result` blocks only.

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

  # A separate, larger ceiling for attachment-bearing lines — the text cap above
  # is deliberately untouched. It has to be larger by construction: base64 grows
  # bytes by 4/3, so a single 400 KB screenshot already encodes past 512 KB and
  # the feature would reject the very thing it exists for. 16 MiB comfortably
  # carries several images at Anthropic's documented 5 MB-per-image ceiling plus
  # text, and is still far below anything a pipe write cares about.
  @max_attachment_bytes 16 * 1024 * 1024

  @doc "The byte ceiling applied to a plain-text encoded line."
  def max_bytes, do: @max_bytes

  @doc "The byte ceiling applied to an encoded line carrying attachment blocks."
  def max_attachment_bytes, do: @max_attachment_bytes

  @doc """
  Encode `text`, and optionally `blocks`, as one newline-terminated JSONL user
  message.

  With no blocks, `content` is the bare string it has always been. With blocks,
  `content` becomes `[%{"type" => "text", "text" => text} | blocks]` — the text
  always first, so the acceptance receipt stays recognisable.

  Returns `{:ok, line}` or `{:error, {:too_large, bytes, limit}}`, where the limit
  is `max_bytes/0` or `max_attachment_bytes/0` depending on which shape was built.
  """
  @spec encode_user(String.t(), [map()]) ::
          {:ok, binary()} | {:error, {:too_large, pos_integer(), pos_integer()}}
  def encode_user(text, blocks \\ [])

  def encode_user(text, []) when is_binary(text) do
    text
    |> user_line()
    |> within(@max_bytes)
  end

  def encode_user(text, blocks) when is_binary(text) and is_list(blocks) do
    [%{"type" => "text", "text" => text} | blocks]
    |> user_line()
    |> within(@max_attachment_bytes)
  end

  defp user_line(content),
    do: Jason.encode!(%{"type" => "user", "message" => %{"role" => "user", "content" => content}})

  defp within(line, limit) do
    size = byte_size(line) + 1

    if size > limit do
      {:error, {:too_large, size, limit}}
    else
      {:ok, line <> "\n"}
    end
  end

  @doc """
  True when a replayed `:user` event is one of OUR messages coming back, rather
  than a tool result being echoed.

  This is the acceptance receipt, and claude provides no marker distinguishing
  the two — only the `content` shape:

    * a **string** is an operator message with no attachments;
    * an array **led by a `text` block** is an operator message with attachments,
      because `encode_user/2` always puts the operator's text first;
    * an array of `tool_result` blocks is a tool return, and is not a receipt.

  The `tool_result` sweep is belt and braces on top of the leading-block check: a
  future claude that prefixed a tool return with text must not be mistaken for a
  steer the operator never sent, since the UI reports STEERED on the strength of
  this alone.
  """
  @spec operator_replay?(map()) :: boolean()
  def operator_replay?(%{"message" => %{"content" => content}}) when is_binary(content), do: true

  def operator_replay?(%{"message" => %{"content" => [%{"type" => "text"} | _rest] = blocks}}),
    do: not Enum.any?(blocks, &match?(%{"type" => "tool_result"}, &1))

  def operator_replay?(_event), do: false
end
