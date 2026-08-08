defmodule BusterClaw.Notes.Links do
  @moduledoc """
  `[[Wiki link]]` parsing for the Notes vault — pure string work, no filesystem.

  Two forms, matching the convention every other Markdown notebook uses:

      [[Remote access]]              -> target "Remote access", no label
      [[Projects/Launch|the plan]]   -> target "Projects/Launch", label "the plan"

  ## Code is not link syntax

  Everything here runs only over the parts of a document that are **not** code.
  A note about this very feature will contain a wiki link inside a fence, and
  turning that into a link would corrupt the sample it exists to show. Fenced
  blocks (``` and ~~~, including indented and longer runs) and inline code spans
  are excluded before any scanning happens — which is also why `replace/2` lives
  here rather than being a `String.replace/3` at the call site.

  `replace/2` is byte-preserving outside the substitutions themselves: lines are
  classified, rewritten in place, and rejoined.
  """

  # Target stops at ], | or a newline; a label may contain anything but ] and
  # newlines, so `[[Note|a | b]]` keeps its pipes in the label rather than
  # silently truncating the user's text.
  @link ~r/\[\[([^\[\]\|\n]+)(?:\|([^\[\]\n]+))?\]\]/

  # A backtick run and its closing partner: the shape of an inline code span.
  @inline_code ~r/(`+[^`]*`+)/

  @doc """
  Every wiki link in the document, in order, with duplicates kept.

  Returns `[%{target: String.t(), label: String.t() | nil}]`.
  """
  def parse(body) when is_binary(body) do
    body
    |> classify()
    |> Enum.flat_map(fn
      {:code, _line} -> []
      {:text, line} -> prose_parts(line)
    end)
    |> Enum.flat_map(&scan/1)
  end

  def parse(_body), do: []

  @doc """
  Rewrite wiki links into ordinary Markdown links the preview can render.

  `resolve` receives a target and returns the note path it names, or `nil`. A
  resolved link becomes `#note/<path>`; an unresolved one becomes
  `#note-new/<target>`, which the editor turns into a "create this note" button.

  Fragment hrefs on purpose: the sanitizer strips custom schemes, and a fragment
  whose click handler never runs is inert — where a `/notes/...` path would be a
  404 the moment JavaScript fails.
  """
  def replace(body, resolve) when is_binary(body) and is_function(resolve, 1) do
    body
    |> classify()
    |> Enum.map_join("\n", fn
      {:code, line} -> line
      {:text, line} -> rewrite(line, resolve)
    end)
  end

  defp scan(text) do
    @link
    |> Regex.scan(text)
    |> Enum.map(fn
      [_raw, target] -> %{target: String.trim(target), label: nil}
      [_raw, target, label] -> %{target: String.trim(target), label: String.trim(label)}
    end)
  end

  defp rewrite(line, resolve) do
    @inline_code
    |> Regex.split(line, include_captures: true)
    |> Enum.map_join(fn chunk ->
      if code_span?(chunk),
        do: chunk,
        else: Regex.replace(@link, chunk, fn _whole, t, l -> markdown_link(t, l, resolve) end)
    end)
  end

  defp markdown_link(target, label, resolve) do
    target = String.trim(target)
    label = String.trim(label)
    text = if label == "", do: target, else: label

    case resolve.(target) do
      nil -> "[#{text}](#note-new/#{URI.encode_www_form(target)})"
      path -> "[#{text}](#note/#{URI.encode_www_form(path)})"
    end
  end

  defp prose_parts(line) do
    @inline_code
    |> Regex.split(line, include_captures: true)
    |> Enum.reject(&code_span?/1)
  end

  defp code_span?(chunk), do: String.starts_with?(chunk, "`")

  # Each line tagged :text or :code by walking fences in order. `fence` holds the
  # opening marker while inside a block and nil while outside; a block closes
  # only on the same character at the same length or longer, which is what lets a
  # four-backtick fence contain three-backtick lines.
  #
  # An unterminated fence keeps every line after it as code: the user is
  # mid-typing, and flickering their sample into links until they close it would
  # be the worst possible moment for it.
  defp classify(body) do
    body
    |> String.split("\n")
    |> Enum.map_reduce(nil, fn line, fence ->
      case {fence, fence_marker(line)} do
        {nil, nil} -> {{:text, line}, nil}
        {nil, marker} -> {{:code, line}, marker}
        {open, nil} -> {{:code, line}, open}
        {open, marker} -> {{:code, line}, if(closes?(open, marker), do: nil, else: open)}
      end
    end)
    |> elem(0)
  end

  defp fence_marker(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
      [_, marker] -> marker
      nil -> nil
    end
  end

  defp closes?(open, marker) do
    String.first(open) == String.first(marker) and
      String.length(marker) >= String.length(open)
  end
end
