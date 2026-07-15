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
  ever stored or rendered.

  The **real** backstop is the enforced app CSP (`script-src 'self' 'nonce-…'`,
  enforced in prod — see `BusterClawWeb.ContentSecurityPolicy`): the browser
  refuses to run inline scripts, `on*` handlers, and `javascript:` URLs that
  reach the DOM regardless of what the regex misses. `sanitize/1` is hardened
  defense-in-depth on top of that, not the sole line — the SVG is kept verbatim
  (no reparse) to preserve drawing fidelity, so it uses targeted strips rather
  than a lossy allowlist.
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
  `<script>`/`<foreignObject>` elements (including unclosed/truncated openers),
  `on*` event-handler attributes (whether space- or solidus-separated), and any
  `href`/`xlink:href` that is not a bare internal `#fragment` reference. Only
  same-document fragment refs survive — `javascript:`, `data:`, `http(s)`, and
  protocol-relative URLs are all dropped (a `data:`/`<use>` ref can smuggle an
  external document with script). Defense-in-depth behind the enforced CSP.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(svg) when is_binary(svg) do
    svg
    # Whole <script>/<foreignObject> elements first...
    |> String.replace(~r/<script\b[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<foreignObject\b[\s\S]*?<\/foreignObject>/i, "")
    # ...then any leftover opener/closer the browser would still parse live
    # (an *unclosed* `<script>` has no `</script>` for the pass above to match).
    |> String.replace(~r/<\/?(?:script|foreignObject)\b[^>]*>?/i, "")
    # on* handlers — HTML allows a solidus as an attribute separator, so
    # `<rect/onload=…>` is a real handler; match whitespace OR `/` before `on`.
    |> String.replace(~r/[\s\/]on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "")
    # href/xlink:href: keep only quoted-or-unquoted `#fragment` values; strip
    # every other scheme. The unquoted branch guards against eating a quoted
    # value by refusing to start on a quote char.
    |> String.replace(
      ~r/\s(?:xlink:)?href\s*=\s*(?:"(?!#)[^"]*"|'(?!#)[^']*'|(?!["'#])[^\s>]+)/i,
      ""
    )
  end

  @doc """
  Make an SVG scalable before it is rendered: if the root `<svg>` tag has no
  `viewBox` but carries numeric `width`/`height` attributes, inject
  `viewBox="0 0 W H"`.

  Without a viewBox there is no user-space→viewport mapping, so the CSS size
  caps on the viewer card and the full-screen modal don't *scale* the drawing —
  they **crop** it to the top-left corner ("doesn't show the full image"). The
  guide below asks the agent for a viewBox, but a drawing that arrives without
  one should still display whole. SVGs with a viewBox, or without inferable
  numeric dimensions (`%`, `em`, none), pass through untouched.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(svg) when is_binary(svg) do
    # Only the first (root) <svg …> tag — nested <svg> elements are content.
    Regex.replace(~r/<svg\b[^>]*>/i, svg, &normalize_root_tag/1, global: false)
  end

  defp normalize_root_tag(tag) do
    with false <- Regex.match?(~r/\bviewBox\s*=/i, tag),
         {:ok, w} <- dimension(tag, "width"),
         {:ok, h} <- dimension(tag, "height") do
      Regex.replace(~r/^<svg\b/i, tag, ~s(\\0 viewBox="0 0 #{w} #{h}"), global: false)
    else
      _ -> tag
    end
  end

  # A positive, unitless-or-px numeric attribute value. Percentages and other
  # units deliberately fail the match — a viewBox can't be inferred from them.
  # The lookbehind keeps `width` from matching inside `stroke-width`.
  defp dimension(tag, name) do
    case Regex.run(
           ~r/(?<![-\w])#{name}\s*=\s*(?:"\s*([0-9.]+)(?:px)?\s*"|'\s*([0-9.]+)(?:px)?\s*'|([0-9.]+)(?:px)?(?=[\s>\/]))/i,
           tag
         ) do
      nil ->
        :error

      captures ->
        raw = captures |> Enum.drop(1) |> Enum.find(&(&1 not in [nil, ""]))

        case Float.parse(raw) do
          {value, ""} when value > 0 -> {:ok, raw}
          _ -> :error
        end
    end
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
