defmodule BusterClaw.Agent.ChatMessageEncoderTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.ChatMessageEncoder, as: Encoder

  describe "encode_user/1" do
    test "produces one newline-terminated JSONL user message" do
      assert {:ok, line} = Encoder.encode_user("hello")
      assert String.ends_with?(line, "\n")

      assert Jason.decode!(line) == %{
               "type" => "user",
               "message" => %{"role" => "user", "content" => "hello"}
             }
    end

    test "carries the text verbatim, including newlines and quotes" do
      text = ~s(line one\nline "two"\ttabbed)
      assert {:ok, line} = Encoder.encode_user(text)
      assert get_in(Jason.decode!(line), ["message", "content"]) == text

      # Exactly one line on the wire: an embedded newline must not split the
      # JSONL record, or the harness reads half a message and desynchronises.
      assert length(String.split(String.trim_trailing(line, "\n"), "\n")) == 1
    end

    test "refuses an oversized message instead of writing a partial line" do
      big = String.duplicate("x", Encoder.max_bytes() + 1)

      assert {:error, {:too_large, size, limit}} = Encoder.encode_user(big)
      assert size > limit
      assert limit == Encoder.max_bytes()
    end

    test "measures the ENCODED size, since escaping can grow the text" do
      # Quotes double in length once escaped, so a payload comfortably under the
      # limit as raw text can exceed it on the wire. Checking the raw string
      # would let that through and wedge the stream.
      quotes = String.duplicate(~s("), div(Encoder.max_bytes(), 2) + 10)
      assert byte_size(quotes) < Encoder.max_bytes()
      assert {:error, {:too_large, _size, _limit}} = Encoder.encode_user(quotes)
    end

    test "accepts a message just under the ceiling" do
      assert {:ok, _line} = Encoder.encode_user(String.duplicate("x", Encoder.max_bytes() - 100))
    end
  end

  describe "operator_replay?/1" do
    test "a replayed operator message has a string content" do
      # This IS the acceptance receipt. `--replay-user-messages` echoes our
      # stdin back, and the string form is the only thing distinguishing it from
      # a tool result — both arrive as type "user".
      assert Encoder.operator_replay?(%{
               "type" => "user",
               "message" => %{"role" => "user", "content" => "redirect the work"}
             })
    end

    test "a tool result is NOT a receipt, even though it is also a user event" do
      refute Encoder.operator_replay?(%{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "tool_result", "content" => "ok"}]
               }
             })
    end

    test "anything unrecognised is not a receipt" do
      refute Encoder.operator_replay?(%{"type" => "assistant"})
      refute Encoder.operator_replay?(%{})
    end
  end
end
