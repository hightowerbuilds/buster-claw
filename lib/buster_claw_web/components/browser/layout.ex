defmodule BusterClawWeb.Browser.Layout do
  @moduledoc """
  The shell every page of the in-app browser's own surface is rendered in —
  home, pages, workspace and history.

  These four are **standalone documents**, not part of the LiveView app: they
  are loaded into the embedded browser's content webview by URL, so they carry
  their own `<head>`, their own stylesheet and no Tailwind. Until 08-08 each one
  also carried its own hand-assembled copy of all of that, and its own
  `escape/1`, and its own near-identical `#121212`/`#f4f1ea`/`#ff4d1c` CSS
  block.

  ## Why this is HEEx and not a heredoc

  The heredocs escaped every interpolation through a private `escape/1`, which
  worked exactly as long as nobody forgot one. HEEx escapes by construction:
  `{@title}` cannot emit markup, and emitting markup on purpose requires
  `raw/1`, which is greppable. That is the whole safety argument for this
  module, and it is worth more than the lines it saves.

  ## The palette lives here once

  As custom properties on `:root`, so a page overriding one rule does not fork
  the colour system. The values are the Industrial Claw identity and match the
  app's own theme.

  ## Page CSS is an attribute, not a slot

  Because **HEEx does not interpolate inside `<style>` or `<script>`** — their
  contents are raw text, so `<style>{raw(css)}</style>` renders the braces
  literally and compiles without complaint. The whole element is therefore
  emitted through `raw/1`, and page CSS arrives as a plain `:css` string.

  `browser_pages.js` is always included: it is attribute-driven and every block
  in it no-ops when its anchor is absent, so one bundle serves all four. It is a
  file rather than inline script because this scope now carries
  `script-src 'self'` — see `BusterClawWeb.Router`'s `:browser_page` pipeline.
  """
  use BusterClawWeb, :html

  @doc """
  Render a page component to the binary `send_resp/3` wants.

  These pages are sent straight from a controller rather than through a view,
  so something has to turn the safe iodata into a string. Doing it here means
  each page module ends with `|> Layout.to_html()` instead of repeating the
  `Phoenix.HTML.Safe` incantation four times.
  """
  def to_html(rendered) do
    rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  attr :title, :string, required: true

  attr :eyebrow, :any,
    default: "Buster Claw",
    doc: "the small label above the heading; nil to render your own header block"

  attr :heading, :string, default: nil, doc: "the <h1>; omit to render your own"

  attr :css, :string,
    default: "",
    doc: "page-specific CSS, emitted after the shared base so it can override"

  slot :inner_block, required: true

  def browser_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
        {raw(style_tag(@css))}
      </head>
      <body>
        <p :if={@eyebrow} class="eyebrow">{@eyebrow}</p>
        <h1 :if={@heading}>{@heading}</h1>
        {render_slot(@inner_block)}
        <script src="/assets/js/browser_pages.js">
        </script>
      </body>
    </html>
    """
  end

  # The whole <style> element is emitted through raw/1 rather than written as a
  # literal tag with `{...}` inside it, because **HEEx does not interpolate
  # inside `<style>` or `<script>`** — it treats their contents as raw text. A
  # literal `<style>{raw(base_css())}</style>` compiles happily and renders the
  # braces, which is why page CSS arrives here as a plain string attribute
  # rather than as a slot.
  #
  # raw/1 is safe by inspection here: `base_css/0` is a compile-time literal,
  # and `css` is CSS authored in a page module — never user input. If that ever
  # stops being true, this is the line that has to change.
  defp style_tag(css) do
    "<style>\n" <> base_css() <> "\n" <> css <> "\n</style>"
  end

  # The base every one of the four pages repeated. `raw/1` above is safe by
  # inspection: this is a compile-time literal with no interpolation, which is
  # the only shape of raw/1 that should ever appear in this module.
  defp base_css do
    """
    :root {
      --bg: #121212;
      --fg: #f4f1ea;
      --accent: #ff4d1c;
      --dim: rgba(244,241,234,.45);
      --dimmer: rgba(244,241,234,.12);
      --label: rgba(244,241,234,.55);
      --mono: ui-monospace, monospace;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; }
    body {
      background: var(--bg); color: var(--fg); padding: 40px 28px;
      font: 15px/1.5 -apple-system, system-ui, sans-serif;
    }
    .eyebrow { font: 700 11px/1 var(--mono); letter-spacing: .12em;
               text-transform: uppercase; color: rgba(244,241,234,.5); }
    h1 { margin: 6px 0 24px; font-size: 26px; font-weight: 900; letter-spacing: -.01em; }
    h2 { margin: 32px 0 0; font-size: 13px; font-weight: 700; letter-spacing: .08em;
         text-transform: uppercase; color: var(--label); }
    ul { list-style: none; margin: 8px 0 0; padding: 0; max-width: 52rem; }
    li { border-top: 1px solid var(--dimmer); }
    a { display: flex; align-items: baseline; gap: 12px; padding: 11px 4px;
        color: var(--fg); text-decoration: none; min-width: 0; }
    a:hover { color: var(--accent); }
    .url { color: var(--dim); font: 12px/1.4 var(--mono);
           overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .empty { color: var(--label); max-width: 40rem; }
    .empty code { color: var(--accent); }
    button.danger { background: transparent; border: 1px solid rgba(244,241,234,.2);
                    color: var(--dim); cursor: pointer; padding: 3px 9px;
                    font: 600 11px/1.6 var(--mono); text-transform: uppercase;
                    letter-spacing: .06em; }
    button.danger:hover { border-color: var(--accent); color: var(--accent); }

    /* The shared confirm modal (assets/js/lib/claw_confirm.js). Its markup is
       built with Tailwind utility classes and these pages have no Tailwind, so
       it is styled through the data attributes the interceptor selects on. */
    [data-claw-confirm-modal] { position: fixed; inset: 0; z-index: 100;
                                display: grid; place-items: center;
                                background: rgba(0,0,0,.5); }
    [data-claw-confirm-modal] [role="alertdialog"] {
      width: 20rem; max-width: 90vw; padding: 20px;
      background: var(--bg); color: var(--fg);
      border: 2px solid rgba(244,241,234,.85); }
    [data-claw-confirm-modal] p { margin: 0; font-size: 14px; }
    [data-claw-confirm-modal] div { display: flex; justify-content: flex-end;
                                    gap: 8px; margin-top: 20px; }
    [data-claw-confirm-modal] button { padding: 5px 12px; font-size: 14px;
                                       cursor: pointer; background: transparent;
                                       color: var(--fg);
                                       border: 2px solid rgba(244,241,234,.85); }
    [data-claw-ok] { background: var(--accent); border-color: var(--accent);
                     color: var(--bg); font-weight: 600; }
    """
  end
end
