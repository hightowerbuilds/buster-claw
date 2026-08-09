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

  describe "encode_user/2 — attachment blocks" do
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
         )

    defp image_block(bytes \\ @png) do
      %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => "image/png",
          "data" => Base.encode64(bytes)
        }
      }
    end

    # The compatibility property, and the diff-noise property. Every turn that
    # has ever run took this branch and must keep taking it unchanged.
    test "no attachments leaves content a BARE STRING, byte-identical to encode_user/1" do
      assert {:ok, one} = Encoder.encode_user("hello")
      assert {:ok, two} = Encoder.encode_user("hello", [])

      assert one == two
      assert get_in(Jason.decode!(two), ["message", "content"]) == "hello"
    end

    test "attachments make content an array, text block first" do
      assert {:ok, line} = Encoder.encode_user("what is this?", [image_block()])

      assert %{"type" => "user", "message" => %{"role" => "user", "content" => content}} =
               Jason.decode!(line)

      assert [%{"type" => "text", "text" => "what is this?"}, block] = content

      # The exact Anthropic format, as measured in Phase 0. An extra key here is
      # a request the harness may reject.
      assert block == %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => Base.encode64(@png)
               }
             }
    end

    test "the emitted base64 decodes back to the file's exact bytes" do
      assert {:ok, line} = Encoder.encode_user("describe it", [image_block()])

      assert [_text, %{"source" => %{"data" => data}}] =
               get_in(Jason.decode!(line), ["message", "content"])

      assert Base.decode64!(data) == @png
    end

    test "several blocks keep their order behind the text" do
      first = image_block(<<1, 2, 3>>)
      second = %{"type" => "text", "text" => "attached file"}

      assert {:ok, line} = Encoder.encode_user("look", [first, second])

      assert [%{"type" => "text", "text" => "look"}, ^first, ^second] =
               get_in(Jason.decode!(line), ["message", "content"])
    end

    test "an attachment line is still exactly one JSONL record" do
      assert {:ok, line} = Encoder.encode_user("line one\nline two", [image_block()])

      assert String.ends_with?(line, "\n")
      assert length(String.split(String.trim_trailing(line, "\n"), "\n")) == 1
    end

    # A single 400 KB screenshot base64s past the 512 KB text cap, so sharing one
    # limit would reject the very thing the feature exists to carry.
    test "attachment lines get their own, larger ceiling" do
      assert Encoder.max_attachment_bytes() > Encoder.max_bytes()

      big = image_block(:crypto.strong_rand_bytes(Encoder.max_bytes()))
      assert {:ok, _line} = Encoder.encode_user("hi", [big])
    end

    test "the text-only ceiling is unchanged by any of this" do
      assert Encoder.max_bytes() == 512 * 1024

      assert {:error, {:too_large, _size, limit}} =
               Encoder.encode_user(String.duplicate("x", Encoder.max_bytes() + 1))

      assert limit == Encoder.max_bytes()
    end

    test "an oversized attachment line is refused against the attachment ceiling" do
      huge = image_block(:crypto.strong_rand_bytes(Encoder.max_attachment_bytes()))

      assert {:error, {:too_large, size, limit}} = Encoder.encode_user("hi", [huge])
      assert size > limit
      assert limit == Encoder.max_attachment_bytes()
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

    # Attachments broke the string-vs-list discriminator: an operator message
    # with an image is now also a list. The second discriminator is the FIRST
    # block, which encode_user/2 guarantees is the operator's text.
    test "an operator message WITH attachments is still a receipt" do
      assert Encoder.operator_replay?(%{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "what is in this image?"},
                   %{"type" => "image", "source" => %{"type" => "base64"}}
                 ]
               }
             })
    end

    test "a tool result led by text is still NOT a receipt" do
      refute Encoder.operator_replay?(%{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "here you go"},
                   %{"type" => "tool_result", "content" => "ok"}
                 ]
               }
             })
    end

    test "a real encoded attachment message round-trips as a receipt" do
      block = %{"type" => "image", "source" => %{"type" => "base64", "data" => "AA=="}}
      assert {:ok, line} = Encoder.encode_user("steer this way", [block])

      assert Encoder.operator_replay?(Jason.decode!(line))
    end

    test "anything unrecognised is not a receipt" do
      refute Encoder.operator_replay?(%{"type" => "assistant"})
      refute Encoder.operator_replay?(%{})
      refute Encoder.operator_replay?(%{"message" => %{"content" => []}})
    end
  end
end
