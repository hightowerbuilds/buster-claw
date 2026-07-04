defmodule BusterClaw.Humo.Expression do
  @moduledoc """
  The Humo expression channel (see HUMO_EXPRESSION_ROADMAP.md).

  Humo's agent can dress or draw into the smoke by emitting fenced blocks in its
  reply — ```` ```humo-<type> {json}``` ````. This module is the parse-and-strip
  seam: it pulls those blocks out of the assistant text, decodes each, and
  returns the text with the blocks removed (they must never show as raw JSON to
  the reader). It is deliberately generic across `type` so new expression modes
  (`style` today; `graph`, `draw` next) ride the same channel.

  The trust boundary lives downstream: this only *extracts and decodes*. Each
  mode's normalizer (e.g. the JS `styleFromSpec`) clamps and validates before it
  ever reaches the GPU. A block whose JSON is malformed is dropped as an
  expression but still stripped from the text — fail closed, never leak.
  """

  # ```humo-<type> {json}``` — the json is any brace-balanced-enough object; the
  # non-greedy `.*?` with the `s` flag stops at the first closing fence.
  @block ~r/```humo-([a-z]+)\s*(\{.*?\})\s*```/s

  @doc """
  Split assistant text into `{clean_text, expressions}`. `expressions` is a list
  of `%{type: String.t(), data: map()}` in document order; `clean_text` is the
  reply with every `humo-*` block removed and trimmed.
  """
  @spec extract(String.t()) :: {String.t(), [%{type: String.t(), data: map()}]}
  def extract(text) when is_binary(text) do
    expressions =
      @block
      |> Regex.scan(text)
      |> Enum.flat_map(fn [_full, type, json] ->
        case Jason.decode(json) do
          {:ok, data} when is_map(data) -> [%{type: type, data: data}]
          _ -> []
        end
      end)

    clean = @block |> Regex.replace(text, "") |> String.trim()
    {clean, expressions}
  end

  def extract(other), do: {other, []}
end
