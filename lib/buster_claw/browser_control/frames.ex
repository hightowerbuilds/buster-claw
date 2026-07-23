defmodule BusterClaw.BrowserControl.Frames do
  @moduledoc """
  NUL-delimited framing for CDP over `--remote-debugging-pipe`.

  On the pipe transport each CDP message is one JSON document terminated by a
  single `\\0` byte, in both directions. This module is the pure layer: bytes in,
  complete frames + remainder out. JSON decoding stays in the CDP client so a
  malformed frame can be handled with the connection state in hand.
  """

  @doc "Wrap one encoded JSON document as iodata ready for the pipe."
  def encode(json) when is_binary(json), do: [json, 0]

  @doc """
  Split a receive buffer into `{complete_frames, rest}`. `rest` is a partial
  frame still awaiting its terminator (often `""`). Empty frames (stray
  doubled terminators) are dropped.
  """
  def split(buffer) when is_binary(buffer) do
    parts = :binary.split(buffer, <<0>>, [:global])
    {frames, [rest]} = Enum.split(parts, -1)
    {Enum.reject(frames, &(&1 == "")), rest}
  end
end
