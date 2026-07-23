defmodule BusterClaw.BrowserControl.FramesTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Frames

  test "encode terminates the document with a NUL byte" do
    assert IO.iodata_to_binary(Frames.encode(~s({"id":1}))) == ~s({"id":1}) <> <<0>>
  end

  test "split returns complete frames and keeps the partial tail" do
    buffer = ~s({"id":1}) <> <<0>> <> ~s({"id":2}) <> <<0>> <> ~s({"id)

    assert Frames.split(buffer) == {[~s({"id":1}), ~s({"id":2})], ~s({"id)}
  end

  test "split with no terminator buffers everything" do
    assert Frames.split(~s({"partial)) == {[], ~s({"partial)}
  end

  test "split of an exact frame leaves an empty rest" do
    assert Frames.split(~s({"a":1}) <> <<0>>) == {[~s({"a":1})], ""}
  end

  test "split drops empty frames from doubled terminators" do
    assert Frames.split(<<0>> <> ~s({"a":1}) <> <<0>> <> <<0>>) == {[~s({"a":1})], ""}
  end

  test "a frame survives arbitrary chunking" do
    # The stream arrives in whatever chunks the pipe hands us; reassembly
    # through the rest-buffer must be byte-boundary independent.
    msg = ~s({"id":7,"result":{"value":"ok"}}) <> <<0>>

    for size <- 1..byte_size(msg) do
      {frames, rest} =
        msg
        |> chunk_every(size)
        |> Enum.reduce({[], ""}, fn chunk, {acc, buf} ->
          {frames, rest} = Frames.split(buf <> chunk)
          {acc ++ frames, rest}
        end)

      assert frames == [~s({"id":7,"result":{"value":"ok"}})]
      assert rest == ""
    end
  end

  defp chunk_every(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_every(binary, size) do
    <<head::binary-size(size), rest::binary>> = binary
    [head | chunk_every(rest, size)]
  end
end
