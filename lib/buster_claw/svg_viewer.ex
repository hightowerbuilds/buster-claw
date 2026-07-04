defmodule BusterClaw.SvgViewer do
  @moduledoc """
  The SVG-viewer channel for the homepage chat.

  Claude draws by emitting a fenced ```` ```svg … ``` ```` block in its reply.
  `extract/1` pulls those blocks out of the assistant text so they render as
  **real, crisp SVGs** in the SVG viewer rather than as raw markup in the
  message bubble. Honest framing: an SVG is shown as an SVG — there is no smoke
  or shader involved here.

  `sanitize/1` is the trust boundary. Unlike a rasterized canvas, the SVG here
  is injected **live into the DOM** (via `Phoenix.HTML.raw/1`), so scripts, event
  handlers, `<foreignObject>`, and external references are stripped before it is
  ever stored or rendered. The app CSP (`script-src 'self' 'nonce-…'`) is the
  real backstop; this is belt-and-suspenders.
  """

  @fence ~r/```svg\s*(.*?)```/s
  @max_bytes 100_000

  @doc """
  Split assistant text into `{clean_text, svgs}`. `svgs` is the list of raw SVG
  strings from each ```` ```svg ```` block (document order); `clean_text` is the
  reply with those blocks removed and trimmed. Only well-formed-looking,
  reasonably-sized `<svg …>` bodies are kept — fail closed.
  """
  @spec extract(String.t()) :: {String.t(), [String.t()]}
  def extract(text) when is_binary(text) do
    svgs =
      @fence
      |> Regex.scan(text)
      |> Enum.flat_map(fn [_full, body] ->
        body = String.trim(body)

        if Regex.match?(~r/^<svg[\s>]/i, body) and byte_size(body) <= @max_bytes,
          do: [body],
          else: []
      end)

    clean = @fence |> Regex.replace(text, "") |> String.trim()
    {clean, svgs}
  end

  def extract(other), do: {other, []}

  @doc """
  Strip anything unsafe from an SVG before it is rendered live in the DOM:
  `<script>`/`<foreignObject>` elements, `on*` event-handler attributes, and
  external `href`/`xlink:href` references (http/https/protocol-relative). Keeps
  internal (`#id`) and `data:` references. Best-effort regex sanitization.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(svg) when is_binary(svg) do
    svg
    |> String.replace(~r/<script\b[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<foreignObject\b[\s\S]*?<\/foreignObject>/i, "")
    |> String.replace(~r/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "")
    |> String.replace(~r/\s(?:xlink:)?href\s*=\s*("|')\s*(?:https?:|\/\/)[^"']*\1/i, "")
  end

  @doc """
  The system-prompt addendum teaching the agent to draw via ```` ```svg ```` blocks
  (appended to the homepage chat's Claude — see `Agent.Chat` `:append_system_prompt`).
  """
  @spec guide() :: String.t()
  def guide do
    """
    When a picture, diagram, chart, or sketch would communicate better than words, \
    DRAW it: emit a fenced ```svg block containing one complete, self-contained \
    <svg>…</svg> (give it a viewBox; no external references, scripts, or event \
    handlers). The block is stripped from your message and rendered crisply in the \
    SVG viewer beside the chat — so refer to it naturally ("see the drawing"), \
    never paste or describe the raw SVG markup. Use it only when it genuinely helps.\
    """
  end
end
