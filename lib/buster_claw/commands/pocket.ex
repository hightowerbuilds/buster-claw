defmodule BusterClaw.Commands.Pocket do
  @moduledoc """
  The `pocket_*` command surface — the agent's read access to the operator's
  Pockets (POCKETS_ROADMAP Part VI Phase 4). Delegated to from
  `BusterClaw.Commands`.

  A Pocket is a named, typed folder of the operator's own media with a
  `POCKET.md` manifest saying what it is for. `BusterClaw.Pocket` holds the
  shape and the reasoning; `BusterClaw.Pockets` finds, validates and resolves
  them. This module only turns three of those answers into wire-shaped maps.

  ## Read-only, and structurally so

  Nothing here writes. More importantly, nothing here can **mount** — no verb in
  this module or its catalog reaches the app-owned registry that lets a Pocket's
  bytes live outside the workspace, and there is deliberately no verb that
  could. Mounting is an operator act in the UI; this surface is on the *using*
  side of that split, the same way The Clinch put a remote caller on the *using*
  side of a credential. `test/buster_claw/commands/pocket_test.exs` holds that
  in place with a lockstep test over the whole command call graph rather than
  with a policy check.

  ## One fence, and only one

  Every byte this module returns comes through `Pockets.resolve/2`. It takes a
  **bare filename**, not a path; it canonicalizes the join back against the
  Pocket's own directory; and it `lstat`s the result so a symlink is seen and
  refused instead of followed out of the Pocket. There is no path handling of
  our own here on purpose — two places that build paths is how one of them ends
  up wrong, and this is the one that is audited.

  `pocket_describe`'s file listing comes from `Pockets.contents/1`, which walks
  with `lstat` for the same reason, so the two answers cannot disagree about
  what a Pocket holds.

  ## Binary files are described, never dumped

  `pocket_read` succeeds on an icon and returns **no bytes**. An image, a font
  or an audio clip is not text and cannot become text; spending the operator's
  context on base64 or on mojibake is a bug rather than a feature, and the
  useful answer — this file exists, it is 4.1 kB, it is not text — is exactly
  what the caller needs to stop asking. Bytes reach the surfaces that can
  actually display them through `Pockets.asset_url/2`, not through here.

  Text is capped at #{64 * 1024} bytes and reports `truncated`, so one large
  file cannot swallow a conversation.

  ## Invalid is a state, not a silence

  `pocket_list` reports invalid Pockets in their own list rather than omitting
  them. `Skills` proved the failure mode this avoids: skipping a malformed file
  is right, but skipping it quietly makes a broken folder indistinguishable from
  a missing one, and the operator has no way to tell which they are looking at.
  """

  alias BusterClaw.Pockets

  # Enough for a manifest, a README, an SVG or a stylesheet; small enough that a
  # stray log file cannot swallow the conversation.
  @max_text_bytes 64 * 1024

  # A file is classified from its head. A null byte is decisive; past that it is
  # a UTF-8 validity question, and only the last few bytes of a truncated read
  # can be a partial codepoint.
  @sniff_bytes 1024
  @max_utf8_trim 3

  # ---------------------------------------------------------------------------
  # What exists
  # ---------------------------------------------------------------------------

  @doc "Every Pocket, valid ones summarised and invalid ones named with a reason."
  def pocket_list(_args \\ %{}) do
    results = Pockets.list_with_errors()

    pockets =
      for {:ok, pocket} <- results, do: summary(pocket)

    invalid =
      for {:error, name, reason} <- results, do: %{name: name, error: error_string(reason)}

    {:ok,
     %{
       dir: Pockets.dir(),
       counts: %{
         total: length(results),
         valid: length(pockets),
         invalid: length(invalid)
       },
       pockets: pockets,
       invalid: invalid
     }}
  end

  # ---------------------------------------------------------------------------
  # What one Pocket is for
  # ---------------------------------------------------------------------------

  @doc "One Pocket in full, including the operator's own prose and its file list."
  def pocket_describe(%{"name" => name}) when is_binary(name) do
    with {:ok, pocket} <- Pockets.load(name) do
      files = Enum.map(Pockets.contents(pocket), &file_entry/1)

      {:ok,
       pocket
       |> summary()
       |> Map.merge(%{
         body: pocket.body,
         counts: %{files: length(files), bytes: Enum.sum(Enum.map(files, & &1.bytes))},
         files: files
       })}
    end
  end

  def pocket_describe(_args), do: {:error, :missing_name}

  # ---------------------------------------------------------------------------
  # One file inside one Pocket
  # ---------------------------------------------------------------------------

  @doc """
  Read one file inside a Pocket, by bare filename.

  The Pocket is loaded first so an unreadable manifest answers with *why* rather
  than with a bare miss, and the filename then goes through `Pockets.resolve/2`
  — the only fence, and the only thing here that touches a path.
  """
  def pocket_read(%{"name" => name, "file" => file})
      when is_binary(name) and is_binary(file) do
    with {:ok, pocket} <- Pockets.load(name) do
      case Pockets.resolve(pocket, file) do
        nil -> {:error, :not_found}
        path -> {:ok, read_file(pocket, file, path)}
      end
    end
  end

  def pocket_read(_args), do: {:error, :missing_name_or_file}

  # ---------------------------------------------------------------------------
  # Shaping
  # ---------------------------------------------------------------------------

  # `binding` is reported as the operator would describe it rather than as the
  # tuple the loader carries: a Pocket is either in the workspace or it points
  # somewhere the operator recorded. `writable` is read from that record and is
  # never from the manifest — the manifest holds description, never permission.
  defp summary(pocket) do
    {binding, writable} = binding_of(pocket)

    %{
      name: pocket.name,
      kind: to_string(pocket.kind),
      description: pocket.description,
      roles: pocket.roles,
      binding: binding,
      writable: writable,
      dir: pocket.dir
    }
  end

  defp binding_of(%{binding: {:mounted, _path, writable}}), do: {"mounted", writable == true}
  defp binding_of(_pocket), do: {"local", false}

  defp file_entry(%{name: name, path: path, bytes: bytes}) do
    %{name: name, bytes: bytes, text: text_file?(path)}
  end

  defp read_file(pocket, file, path) do
    base = %{
      pocket: pocket.name,
      file: file,
      path: path,
      bytes: byte_size_of(path)
    }

    case read_head(path, @max_text_bytes + 1) do
      {:ok, data} ->
        Map.merge(base, text_result(data))

      :error ->
        Map.merge(base, %{text: false, truncated: false, content: nil, note: unreadable()})
    end
  end

  defp text_result(data) do
    truncated? = byte_size(data) > @max_text_bytes
    candidate = if truncated?, do: binary_part(data, 0, @max_text_bytes), else: data

    case as_text(candidate) do
      {:ok, text} ->
        %{text: true, truncated: truncated?, content: text}

      :binary ->
        %{text: false, truncated: false, content: nil, note: binary_note()}
    end
  end

  # A null byte settles it. Past that, the only reason a text file's head fails
  # UTF-8 validation is a codepoint split by the read limit, so a few bytes come
  # off the end before the answer is believed.
  defp as_text(data) do
    if :binary.match(data, <<0>>) == :nomatch do
      trim_to_utf8(data, @max_utf8_trim)
    else
      :binary
    end
  end

  defp trim_to_utf8(data, remaining) do
    cond do
      String.valid?(data) -> {:ok, data}
      remaining > 0 and byte_size(data) > 0 -> trim_to_utf8(chop(data), remaining - 1)
      true -> :binary
    end
  end

  defp chop(data), do: binary_part(data, 0, byte_size(data) - 1)

  defp text_file?(path) do
    case read_head(path, @sniff_bytes) do
      {:ok, data} -> match?({:ok, _}, as_text(data))
      :error -> false
    end
  end

  # Bounded by construction: a Pocket may hold a file of any size, and reading
  # one into memory to find out it is a video is the mistake this avoids.
  defp read_head(path, limit) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        data = IO.binread(io, limit)
        File.close(io)

        case data do
          :eof -> {:ok, ""}
          bin when is_binary(bin) -> {:ok, bin}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp byte_size_of(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp binary_note do
    "Not text — the bytes are deliberately not returned. Describe it, or show it " <>
      "on a surface that can display it; a file like this in a transcript is noise."
  end

  defp unreadable do
    "The file could not be opened for reading."
  end

  defp error_string({:unknown_kind, kind}), do: "unknown_kind: #{kind}"
  defp error_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_string(reason), do: inspect(reason)
end
