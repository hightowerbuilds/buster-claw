defmodule BusterClaw.AudioName do
  @moduledoc """
  Filename sanitation for user-visible audio: the one `safe_name/1` that Music,
  Sound, the Studio, and StudioMix all share.

  A leaf on purpose (CODE_QUALITY_REFACTOR_ROADMAP Phase 1): it lived in
  `Music`, and `Notifications.Sound` calling it there while `Music` called
  `Sound.renamed_to/2` made the two a dependency cycle for the sake of a
  sanitizer.

  Deliberately **more permissive than `Sound`'s chime sanitizer**, which
  replaces every non-word character including spaces. That is fine for a chime
  and would be destructive here: `Music.track_info/1` splits on `" - "`, so a
  sanitizer that turned spaces into dashes would turn
  "Miles Davis - So What.mp3" into "Miles-Davis---So-What.mp3" and silently
  destroy the naming convention the library is built around. Spaces,
  parentheses, and apostrophes are how music files are actually named.
  """

  @name_allowed ~r/[^\p{L}\p{N} .,\-_()\[\]&'!+#@]/u
  @max_stem_bytes 180

  @doc """
  The basename an uploaded file will be stored under, before collision handling.

  `Path.basename/1` first, so a name carrying directories (`../../etc/x.mp3`)
  reduces to its last segment before anything else looks at it. Then everything
  outside the allowed set becomes `-`, runs of whitespace collapse, and leading
  dots go so an upload cannot create a dotfile.
  """
  def safe_name(client_name) when is_binary(client_name) do
    # The extension comes from the ORIGINAL name, which is the same place
    # `Music.store/2` reads it for the accept check. Deriving it from a trimmed
    # or basenamed copy lets the two disagree: `"   .mp3"` trims to `".mp3"`,
    # which Elixir reads as a dotfile with NO extension, so the upload passed
    # the `.mp3` gate and then landed as a file called `track` — invisible to
    # `Music.list/0`, a success message for a track that never appeared.
    ext = client_name |> Path.extname() |> String.downcase()

    stem =
      client_name
      |> Path.basename()
      |> strip_extension(ext)
      |> String.replace(@name_allowed, "-")
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/^[.\s]+/u, "")
      |> String.trim()
      |> truncate_bytes(@max_stem_bytes)
      |> String.trim()

    if stem == "", do: "track" <> ext, else: stem <> ext
  end

  defp strip_extension(base, ""), do: base

  defp strip_extension(base, ext) do
    if String.ends_with?(String.downcase(base), ext) do
      binary_part(base, 0, byte_size(base) - byte_size(ext))
    else
      base
    end
  end

  # Truncate to a byte budget without splitting a grapheme — a filename is
  # bytes to the filesystem but characters to a person.
  defp truncate_bytes(string, max) when byte_size(string) <= max, do: string

  defp truncate_bytes(string, max) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      next = size + byte_size(grapheme)
      if next > max, do: {:halt, {acc, size}}, else: {:cont, {[grapheme | acc], next}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end
end
