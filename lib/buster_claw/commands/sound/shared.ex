defmodule BusterClaw.Commands.Sound.Shared do
  @moduledoc false
  # The helpers both halves of the `sound_*` surface need: argument validation
  # (`validate_name/1`, `boolean/2`, `blank_to_nil/1`, `stored_name/2`), source
  # resolution (`studio_source/1`, `editable_clip/1`, `peak_of/1`,
  # `byte_size_of/1`, `internal_format/1`) and the Library-root containment
  # that `sound_import` and `sound_probe` share (`under_library/1`,
  # `library_root/0`, `relative_path/2`, `contained/2`, `import_origin/1`).
  # Public only so `Sound.Library` and `Sound.Edit` can reach them; not a
  # command surface.
  alias BusterClaw.AudioName
  alias BusterClaw.Studio.Editor

  # A name is a basename or it is nothing. `path_for/1` already allowlists
  # against a directory listing, so traversal could never resolve — but a
  # traversal attempt deserves its own named refusal rather than an ambiguous
  # "not found".
  def validate_name(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      trimmed in [".", ".."] -> {:error, :invalid_name}
      String.contains?(trimmed, ["/", "\\", <<0>>]) -> {:error, :invalid_name}
      Path.basename(trimmed) != trimmed -> {:error, :invalid_name}
      true -> {:ok, trimmed}
    end
  end

  # `peak/1` is defined for PCM16 only. A 24-bit WAV is a legitimate thing to
  # find on disk and must report "no peak", not raise.
  def peak_of(%Editor{bits: 16} = clip), do: Editor.peak(clip)
  def peak_of(%Editor{}), do: nil

  # Where the file being imported comes from: a path relative to the Library
  # root. (An `event_id` naming a phone recording was the other way until the
  # phone left on 10-15.)
  def import_origin(%{"path" => relative}) when is_binary(relative) do
    with {:ok, path} <- under_library(relative) do
      {:ok,
       %{event_id: nil, relative: String.trim(relative), path: path, name: Path.basename(path)}}
    end
  end

  # A path that is not a string at all is a bad path, not a missing one.
  def import_origin(%{"path" => path}) when not is_nil(path), do: {:error, :invalid_path}

  def import_origin(_args), do: {:error, :missing_source}

  # **The security boundary of this module.** Everywhere else a caller supplies
  # a basename that is allowlisted against a directory listing; here a caller
  # supplies a path, so this function is the only thing standing between an
  # agent and every file this app can read.
  #
  # Two independent checks, because one of them being subtly wrong is the whole
  # risk: the segments are scanned before the filesystem is touched at all
  # (absolute, `~`, `..`, empty segment, null byte), and the *expanded* result
  # is then required to sit under the expanded root. The second check is what
  # catches anything the first one failed to imagine.
  #
  # Note that `recording_path` values go through it too. They were written by
  # the drain from a relay row, which makes them data from off this machine —
  # trusted enough to store, not trusted enough to join into a path unchecked.
  def under_library(relative) when is_binary(relative) do
    with {:ok, root} <- library_root(),
         {:ok, clean} <- relative_path(relative),
         {:ok, path} <- contained(root, clean) do
      if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
    end
  end

  def under_library(_relative), do: {:error, :invalid_path}

  # Read from the env rather than through `Artifact.root/0`, which raises when
  # unset — an unconfigured Library root is a named error here, not a crash.
  def library_root do
    case Application.get_env(:buster_claw, :library_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _unset -> {:error, :no_library_root}
    end
  end

  def relative_path(relative) do
    trimmed = String.trim(relative)
    segments = String.split(trimmed, "/")

    cond do
      trimmed == "" -> {:error, :invalid_path}
      String.contains?(trimmed, <<0>>) -> {:error, :invalid_path}
      Path.type(trimmed) != :relative -> {:error, :absolute_path}
      String.starts_with?(trimmed, "~") -> {:error, :absolute_path}
      Enum.any?(segments, &(&1 in ["..", "."])) -> {:error, :traversal}
      Enum.any?(segments, &(&1 == "")) -> {:error, :invalid_path}
      true -> {:ok, trimmed}
    end
  end

  def contained(root, relative) do
    path = Path.expand(Path.join(root, relative))

    if String.starts_with?(path, root <> "/"), do: {:ok, path}, else: {:error, :traversal}
  end

  # Editing is defined for PCM16 only: `fade/2` and `normalize/2` match on it,
  # and a 24-bit WAV dropped into the studio by hand would otherwise raise
  # instead of being refused. Everything `sound_import` writes qualifies.
  def editable_clip(path) do
    case Editor.read(path) do
      {:ok, %Editor{bits: 16} = clip} -> {:ok, clip}
      {:ok, %Editor{}} -> {:error, :unsupported_format}
      {:error, _reason} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  # The name to run `sound_import` for is the honest answer to "that audio is
  # not here" — never a silent second write into the studio.
  def studio_source(name) do
    case Editor.path_for(name) do
      nil -> {:error, {:not_imported, name}}
      path -> {:ok, path}
    end
  end

  # Forced to `.wav` because that is what every writer here renders: an imported
  # mp3 saved under its original extension would be a WAV lying about its
  # container. Shared by `sound_import` and the editing verbs so they cannot
  # disagree about what a legal stored name is.
  def stored_name(name) do
    with {:ok, clean} <- validate_name(name) do
      {:ok, AudioName.safe_name(Path.rootname(clean) <> ".wav")}
    end
  end

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_value), do: nil

  def boolean(value, _default) when is_boolean(value), do: value
  def boolean("true", _default), do: true
  def boolean("false", _default), do: false
  def boolean(_value, default), do: default

  def internal_format do
    {rate, channels, bits} = Editor.internal_format()
    %{sample_rate: rate, channels: channels, bits: bits}
  end

  def byte_size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end
end
