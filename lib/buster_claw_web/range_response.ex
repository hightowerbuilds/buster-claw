defmodule BusterClawWeb.RangeResponse do
  @moduledoc """
  Serve a file with HTTP byte-range support (RFC 7233).

  ## Why this exists

  Before this module, every audio route in the app answered with a whole-file
  `200`. That is fine for what they served — a notification chime is a second
  long, a voicemail a few dozen — and wrong for anything you would scrub
  through:

  - **Seeking re-downloads.** Without `Accept-Ranges`, dragging a scrubber makes
    the client re-request from byte 0.
  - **WKWebView is the strict case, and it is the one that ships.** The Tauri
    shell renders in WKWebView, whose media stack issues `Range: bytes=0-` and
    expects `206` with a correct `Content-Range`. A `200` can leave an `<audio>`
    element unable to report duration or seek at all — so this is a bug class
    that looks fine in a dev browser tab and misbehaves only in the packaged
    app.

  ## Behavior

  `serve/3` always advertises `Accept-Ranges: bytes`, then:

  | Request | Response |
  |---|---|
  | no `Range` | `200`, whole file |
  | `bytes=0-499` | `206` + `Content-Range: bytes 0-499/SIZE` |
  | `bytes=500-` | `206`, 500 through end |
  | `bytes=-500` | `206`, final 500 bytes |
  | first byte past EOF, or `bytes=-0` | `416` + `Content-Range: bytes */SIZE` |
  | malformed, non-`bytes` unit, or multi-range | `200`, whole file |

  Ignoring a header we don't fully support is explicitly allowed by RFC 7233
  §3.1 ("a server MAY ignore the Range header field"), and it is the safe
  direction: a client that asked for bytes 0-499 and receives the whole file
  still works, whereas one that receives a wrong slice does not. Multi-range
  requests would require a `multipart/byteranges` body; no media element in this
  app's path sends one, so serving the whole file is both legal and simpler than
  a code path nothing exercises.

  An end byte past EOF is clamped rather than refused — clients legitimately ask
  for more than exists (`bytes=0-99999` on a 500-byte file), and RFC 7233 §2.1
  says to treat that as the remainder of the representation.
  """

  import Plug.Conn

  @doc """
  Send `path` honoring any `Range` request header.

  ## Options

    * `:content_type` — required.
    * `:cache_control` — defaults to `"private, no-cache"`.
  """
  def serve(conn, path, opts) do
    size = file_size(path)

    conn =
      conn
      |> put_resp_header("content-type", Keyword.fetch!(opts, :content_type))
      |> put_resp_header("cache-control", Keyword.get(opts, :cache_control, "private, no-cache"))
      # Advertised on every response, including the 200 fall-through: it is how
      # a client learns it may seek at all.
      |> put_resp_header("accept-ranges", "bytes")

    case parse_range(get_req_header(conn, "range"), size) do
      :none ->
        send_file(conn, 200, path)

      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  # Exactly one Range header, or none. Two Range headers is a malformed request,
  # not a request for two ranges.
  defp parse_range([value], size), do: parse_spec(value, size)
  defp parse_range(_headers, _size), do: :none

  defp parse_spec("bytes=" <> spec, size) do
    if String.contains?(spec, ",") do
      # Multi-range: legal to ignore, and nothing in this app sends one.
      :none
    else
      # Not trimmed on purpose. The grammar has no whitespace here, so
      # `bytes= -5` is malformed — and the fall-through for malformed is the
      # whole file, which is a safe answer to a request we can't read. Being
      # lenient would mean interpreting a header no real client sends, on a
      # code path no real client exercises.
      bounds(spec, size)
    end
  end

  # A unit other than bytes ("items=0-5") is not ours to interpret.
  defp parse_spec(_value, _size), do: :none

  # Suffix form: the LAST n bytes. `bytes=-0` requests nothing, which RFC 7233
  # §2.1 makes unsatisfiable rather than empty.
  defp bounds("-" <> suffix, size) do
    case integer(suffix) do
      nil -> :none
      0 -> :unsatisfiable
      # An empty file has no last-n bytes to give.
      _n when size == 0 -> :unsatisfiable
      # A suffix longer than the file is the whole file, not an error.
      n -> {:ok, max(size - n, 0), size - 1}
    end
  end

  defp bounds(spec, size) do
    case String.split(spec, "-", parts: 2) do
      [first, ""] -> open_ended(integer(first), size)
      [first, last] -> closed(integer(first), integer(last), size)
      _ -> :none
    end
  end

  defp open_ended(nil, _size), do: :none
  defp open_ended(first, size) when first >= size, do: :unsatisfiable
  defp open_ended(first, size), do: {:ok, first, size - 1}

  defp closed(nil, _last, _size), do: :none
  defp closed(_first, nil, _size), do: :none
  # An inverted range (`bytes=500-100`) is malformed, not unsatisfiable: the
  # whole header is invalid, so it is ignored rather than refused.
  defp closed(first, last, _size) when first > last, do: :none
  defp closed(first, _last, size) when first >= size, do: :unsatisfiable
  # Clamp an end past EOF to the last byte (RFC 7233 §2.1).
  defp closed(first, last, size), do: {:ok, first, min(last, size - 1)}

  # Integer.parse would accept "12abc"; a byte-range spec must be digits only.
  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end
end
