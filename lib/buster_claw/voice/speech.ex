defmodule BusterClaw.Voice.Speech do
  @moduledoc """
  Turns an assistant reply into something worth hearing.

  The chat speaks its replies through `say(1)`, and until now it spoke them
  *verbatim* — markdown and all. A synthesizer has no idea that a fenced block is
  code rather than prose, so it reads every brace, underscore and `:noreply`
  aloud, and it reads a URL one path segment at a time.

  ## The measurement that motivated this

  One reply — a sentence of prose, one seven-line Elixir block, and a link:

  | Spoken | Audio |
  |---|---|
  | The reply verbatim | **23.6 s** |
  | Its prose alone | **3.3 s** |

  Measured 09-02-26 with `say -o … -f`, at the default voice and rate. **Seven
  times the listening for the same meaning**, and the six extra seconds of it are
  a person waiting for punctuation to finish. Barge-in exists, but needing it on
  every reply that contains code is not a feature.

  ## What it does and does not do

  It is a **speech** transform, not a markdown renderer. The bubble on screen
  still shows the real thing; this only decides what reaches the synthesizer, and
  the two are allowed to differ — that is the point.

  Structure that carries no sound is dropped (emphasis markers, bullets, heading
  hashes, rules). Structure that a listener needs to *know about* but not hear is
  announced instead: a code block becomes "elixir code block", a table becomes "a
  table", a URL becomes "a link to example.com". **Announcing beats silence**,
  because a listener who is told there was code can go and look, while one who
  hears a sentence quietly missing its middle cannot.

  Nothing is truncated. A long reply takes a long time to say, and silently
  dropping the end of an answer is a worse failure than a slow one.
  """

  # Order matters, and it is the whole correctness story of this module.
  #
  # Fenced blocks come out FIRST, because their contents are arbitrary text that
  # looks like every other rule here — a comment starting with `#` is not a
  # heading, and `|` in a pipeline is not a table. Images precede links because
  # `![alt](url)` is a link pattern with one character in front of it, and a link
  # rule run first would leave a stray `!`.
  @fenced ~r/```[ \t]*([A-Za-z0-9_+#-]*)[^\n]*\n.*?(?:```|\z)/s
  @unterminated ~r/```[ \t]*([A-Za-z0-9_+#-]*)[^\n]*\n[\s\S]*\z/
  @table_block ~r/(?:^[ \t]*\|.*\n?){2,}/m
  @image ~r/!\[([^\]]*)\]\([^)]*\)/
  @link ~r/\[([^\]]+)\]\([^)]*\)/
  @bare_url ~r{<?https?://([^\s/>)\]]+)(?:[^\s>)\]]*)>?}
  @inline_code ~r/`([^`\n]+)`/
  # `\#` escaped: an unescaped `#{` opens interpolation inside a sigil.
  @heading ~r/^[ \t]{0,3}\#{1,6}[ \t]+/m
  @blockquote ~r/^[ \t]{0,3}>[ \t]?/m
  @rule ~r/^[ \t]{0,3}(?:[-*_][ \t]*){3,}$/m
  @bullet ~r/^[ \t]*(?:[-*+]|\d+[.)])[ \t]+/m
  # Deliberately no `_`/`__`. Underscore emphasis is indistinguishable from a
  # snake_case identifier here — `some_var_name` would match `_var_` and be spoken
  # as "somevarname", mangling the one kind of word this app says most often.
  # A synthesizer reads a stray underscore as nothing anyway, so leaving them in
  # costs a listener nothing and removing them costs correctness.
  @emphasis ~r/(\*\*\*|\*\*|\*|~~)(?=\S)(.*?\S)\1/s
  @spaces ~r/[ \t]{2,}/
  @blank_runs ~r/\n{3,}/

  @doc """
  Rewrite `markdown` as a line fit for a speech synthesizer.

  Returns a trimmed string, which may be empty — a reply that was *only* a code
  block has nothing to say beyond announcing it, and an empty string is the
  caller's signal to stay quiet rather than speak the word "nothing".
  """
  @spec to_spoken(String.t() | nil) :: String.t()
  def to_spoken(nil), do: ""

  def to_spoken(markdown) when is_binary(markdown) do
    markdown
    |> then(&Regex.replace(@fenced, &1, fn _m, lang -> code_marker(lang) end))
    |> then(&Regex.replace(@unterminated, &1, fn _m, lang -> code_marker(lang) end))
    |> then(&Regex.replace(@table_block, &1, " a table. "))
    |> then(&Regex.replace(@image, &1, fn _m, alt -> image_marker(alt) end))
    |> then(&Regex.replace(@link, &1, fn _m, label -> " #{label} " end))
    |> then(&Regex.replace(@bare_url, &1, fn _m, host -> " a link to #{strip_www(host)} " end))
    |> then(&Regex.replace(@inline_code, &1, fn _m, code -> code end))
    |> then(&Regex.replace(@rule, &1, ""))
    |> then(&Regex.replace(@heading, &1, ""))
    |> then(&Regex.replace(@blockquote, &1, ""))
    |> then(&Regex.replace(@bullet, &1, ""))
    |> then(&Regex.replace(@emphasis, &1, fn _m, _marker, inner -> inner end))
    |> then(&Regex.replace(@spaces, &1, " "))
    |> then(&Regex.replace(@blank_runs, &1, "\n\n"))
    |> String.trim()
  end

  # A language tag is worth saying — "elixir code block" tells a listener what
  # they are being spared. A bare fence gets the generic form rather than an
  # awkward leading space.
  defp code_marker(""), do: " code block. "
  defp code_marker(lang), do: " #{lang} code block. "

  # Alt text is what the author wrote for someone who cannot see the image, which
  # is exactly this listener.
  defp image_marker(""), do: " an image. "
  defp image_marker(alt), do: " image: #{alt}. "

  # "www dot example dot com" is three words of nothing.
  defp strip_www("www." <> rest), do: rest
  defp strip_www(host), do: host
end
