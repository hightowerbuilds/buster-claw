defmodule BusterClaw.Notes.Links do
  @moduledoc """
  `[[Wiki link]]` parsing for the Notes vault — pure string work, no filesystem.

  Two forms, matching the convention every other Markdown notebook uses:

      [[Remote access]]              -> target "Remote access", no label
      [[Projects/Launch|the plan]]   -> target "Projects/Launch", label "the plan"

  ## Code is not link syntax

  Everything here runs only over the parts of a document that are **not** code.
  A note about this very feature will contain a wiki link inside a fence, and
  counting that as a link would make it a backlink of itself. Fenced blocks
  (``` and ~~~, including indented and longer runs) and inline code spans are
  excluded before any scanning happens — which is why the fence walk below lives
  here rather than being a `Regex.scan/2` at the call site.

  ## What used to be here

  `replace/2` rewrote wiki links into `#note/…` Markdown links for the Notes
  preview pane. `daily-growth/archive/08-09-26-notes-editor.md` Phase 1 deleted that pane — the editor
  renders its own Markdown now, and a clicked link reaches
  `Notes.resolve_link/2` directly with its raw target. Nothing rewrites a
  document's text any more, which is a better place to be.
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

  defp scan(text) do
    @link
    |> Regex.scan(text)
    |> Enum.map(fn
      [_raw, target] -> %{target: String.trim(target), label: nil}
      [_raw, target, label] -> %{target: String.trim(target), label: String.trim(label)}
    end)
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
