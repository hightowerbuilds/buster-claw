defmodule BusterClaw.Sketch.ImageInfo do
  @moduledoc """
  What a file actually is, read from its first bytes — and how big it is.

  `SKETCH_ROADMAP` Phase 4. Two jobs that turn out to be one parse:

  1. **Is this really an image?** An extension is a claim and the bytes are
     evidence. A `.png` that is not a PNG should be refused before it is written
     into a workspace folder and served back over a route.
  2. **What size is it?** The element needs intrinsic dimensions to be placed
     without distorting it, and the native drag path never gives the browser the
     bytes — so asking the client is not an option in the packaged app.

  Doing both in one place means a file can never be sized without having been
  identified, which is the ordering that matters.

  ## Deliberately four formats and no library

  PNG, GIF, JPEG, WebP — the formats a screenshot or a pasted image is actually
  in. Each is a fixed header read, not a decode: nothing here allocates a pixel
  buffer, so a hostile file cannot cost more than the bytes it was going to cost
  anyway. That is also why there is no dependency — an image *decoder* would be a
  much larger attack surface than the thing it is checking.

  An unrecognised format is `{:error, :unsupported}`, never a guess.
  """

  import Bitwise

  @max_dimension 20_000

  @type info :: %{
          format: :png | :gif | :jpeg | :webp,
          width: pos_integer(),
          height: pos_integer()
        }

  @doc """
  Identify and measure. `{:ok, %{format, width, height}}` or `{:error, reason}`.
  """
  @spec inspect_binary(binary()) :: {:ok, info()} | {:error, atom()}
  def inspect_binary(binary) when is_binary(binary) do
    with {:ok, info} <- parse(binary) do
      validate(info)
    end
  end

  def inspect_binary(_other), do: {:error, :not_binary}

  @doc "Identify and measure a file on disk, reading only what the header needs."
  @spec inspect_file(Path.t()) :: {:ok, info()} | {:error, atom()}
  def inspect_file(path) do
    # 64 KB is far more than any of these headers need and bounded regardless of
    # what was handed to us — a native drop names a path we did not choose.
    case File.open(path, [:read, :binary], &IO.binread(&1, 64 * 1024)) do
      {:ok, :eof} -> {:error, :empty}
      {:ok, data} when is_binary(data) -> inspect_binary(data)
      {:ok, _other} -> {:error, :unreadable}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  @doc "The file extension this format should be stored with."
  def extension(:png), do: ".png"
  def extension(:gif), do: ".gif"
  def extension(:jpeg), do: ".jpg"
  def extension(:webp), do: ".webp"

  @doc "The media type to serve it back as."
  def media_type(:png), do: "image/png"
  def media_type(:gif), do: "image/gif"
  def media_type(:jpeg), do: "image/jpeg"
  def media_type(:webp), do: "image/webp"

  @doc "The formats this recognises."
  def formats, do: [:png, :gif, :jpeg, :webp]

  # --- parsing --------------------------------------------------------------

  # PNG: the 8-byte signature, then IHDR, whose first two fields are the
  # dimensions as big-endian 32-bit integers.
  defp parse(<<137, "PNG\r\n", 26, "\n", _len::32, "IHDR", w::32, h::32, _rest::binary>>),
    do: {:ok, %{format: :png, width: w, height: h}}

  # GIF: the signature, then the logical screen descriptor — little-endian, which
  # is the one place these formats disagree about byte order.
  defp parse(<<"GIF8", v, "a", w::little-16, h::little-16, _rest::binary>>) when v in [?7, ?9],
    do: {:ok, %{format: :gif, width: w, height: h}}

  # WebP has three sub-formats and they do not share a header. All are RIFF.
  defp parse(<<"RIFF", _size::32, "WEBP", rest::binary>>), do: parse_webp(rest)

  # JPEG stores its dimensions in a frame header that can be anywhere after the
  # start marker, so this one has to walk the segments.
  defp parse(<<0xFF, 0xD8, rest::binary>>), do: parse_jpeg(rest)

  defp parse(_other), do: {:error, :unsupported}

  # Lossy: dimensions are 14 bits each, after the 3-byte start code and the
  # "9d 01 2a" signature.
  defp parse_webp(
         <<"VP8 ", _size::32, _start::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16,
           _r::binary>>
       ),
       do: {:ok, %{format: :webp, width: w &&& 0x3FFF, height: h &&& 0x3FFF}}

  # Lossless: 14-bit dimensions packed into 28 bits, each stored minus one.
  defp parse_webp(<<"VP8L", _size::32, 0x2F, bits::little-32, _rest::binary>>) do
    {:ok, %{format: :webp, width: (bits &&& 0x3FFF) + 1, height: (bits >>> 14 &&& 0x3FFF) + 1}}
  end

  # Extended: 24-bit dimensions, each stored minus one.
  defp parse_webp(<<"VP8X", _size::32, _flags::32, w::little-24, h::little-24, _rest::binary>>),
    do: {:ok, %{format: :webp, width: w + 1, height: h + 1}}

  defp parse_webp(_other), do: {:error, :unsupported}

  # Every JPEG segment is `FF <marker> <length:16>`, except the standalone ones.
  # A start-of-frame marker carries the dimensions; everything else is skipped by
  # its own length, which is what makes this a walk rather than a search for a
  # byte pattern that could occur inside compressed data.
  defp parse_jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9 or marker == 0x01,
    do: parse_jpeg(rest)

  defp parse_jpeg(<<0xFF, marker, len::16, body::binary>>) do
    cond do
      sof?(marker) ->
        case body do
          <<_precision, h::16, w::16, _rest::binary>> ->
            {:ok, %{format: :jpeg, width: w, height: h}}

          _ ->
            {:error, :truncated}
        end

      # Start of scan: compressed data follows and there is no frame header
      # after it. Refusing here beats scanning entropy-coded bytes for something
      # that looks like a marker.
      marker == 0xDA ->
        {:error, :no_frame_header}

      true ->
        skip = len - 2

        case body do
          <<_skipped::binary-size(skip), rest::binary>> -> parse_jpeg(rest)
          _ -> {:error, :truncated}
        end
    end
  end

  defp parse_jpeg(<<0xFF, rest::binary>>), do: parse_jpeg(rest)
  defp parse_jpeg(_other), do: {:error, :truncated}

  # C4 is a Huffman table, C8 is reserved, CC is arithmetic coding conditioning —
  # they share the range and are not frames.
  defp sof?(marker), do: marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC]

  defp validate(%{width: w, height: h} = info) do
    cond do
      w <= 0 or h <= 0 -> {:error, :zero_dimension}
      w > @max_dimension or h > @max_dimension -> {:error, :too_large}
      true -> {:ok, info}
    end
  end
end
