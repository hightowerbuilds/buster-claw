defmodule BusterClaw.Manual do
  @moduledoc """
  Generates the **Manual** as a single, self-contained, dark-themed HTML document
  from the in-app User Guide sections (`BusterClaw.UserGuide`).

  Installed (as `MANUAL.html`) into `<workspace>/pages/` by `BusterClaw.Pages`
  and openable from the in-app browser.
  """
  alias BusterClaw.UserGuide

  @doc "The full manual as a single self-contained HTML document."
  def html do
    sections = UserGuide.sections()

    nav =
      Enum.map_join(sections, "\n", fn s ->
        ~s(<a class="toc" href="##{s.key}">#{escape(s.label)}</a>)
      end)

    body =
      Enum.map_join(sections, "\n", fn s ->
        """
        <section id="#{s.key}">
          <h2>#{escape(s.label)}</h2>
          #{s.html}
        </section>
        """
      end)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Buster Claw — Manual</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; }
      body {
        background: #121212; color: #f4f1ea; padding: 48px 28px 96px;
        font: 16px/1.6 -apple-system, system-ui, sans-serif;
      }
      .wrap { max-width: 52rem; margin: 0 auto; }
      .eyebrow { font: 700 11px/1 ui-monospace, monospace; letter-spacing: .12em;
                 text-transform: uppercase; color: rgba(244,241,234,.5); }
      h1 { margin: 6px 0 8px; font-size: 30px; font-weight: 900; letter-spacing: -.01em; }
      h2 { margin: 48px 0 16px; font-size: 22px; font-weight: 800;
           padding-top: 24px; border-top: 1px solid rgba(244,241,234,.12); }
      h3 { margin: 28px 0 10px; font-size: 17px; font-weight: 700; }
      p, li { color: rgba(244,241,234,.85); }
      a { color: #ff4d1c; text-decoration: none; }
      a:hover { text-decoration: underline; }
      nav { display: flex; flex-wrap: wrap; gap: 8px; margin: 20px 0 8px; }
      a.toc { padding: 6px 12px; border: 1px solid rgba(244,241,234,.2);
              border-radius: 3px; color: #f4f1ea; font: 600 13px/1 ui-monospace, monospace; }
      a.toc:hover { border-color: #ff4d1c; color: #ff4d1c; text-decoration: none; }
      code { font: 13px/1.5 ui-monospace, monospace; background: rgba(244,241,234,.08);
             padding: 1px 5px; border-radius: 3px; }
      pre { background: #1c1c1c; border: 1px solid rgba(244,241,234,.12); border-radius: 4px;
            padding: 14px 16px; overflow-x: auto; }
      pre code { background: transparent; padding: 0; }
      ul, ol { padding-left: 1.4em; }
      blockquote { margin: 16px 0; padding: 4px 16px; border-left: 3px solid #ff4d1c;
                   color: rgba(244,241,234,.7); }
    </style>
    </head>
    <body>
      <div class="wrap">
        <p class="eyebrow">Buster Claw</p>
        <h1>Manual</h1>
        <nav>
        #{nav}
        </nav>
        #{body}
      </div>
    </body>
    </html>
    """
  end

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
