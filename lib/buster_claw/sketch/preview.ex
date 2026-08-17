defmodule BusterClaw.Sketch.Preview do
  @moduledoc """
  A sketch, rasterised — the second half of `D4`'s dual representation.

  The model gets the element list *and* a picture, because neither is sufficient
  on its own: the JSON says what is addressable and the image says what it
  actually looks like — which marks overlap, which label is unreadable, where the
  empty space is. Every system surveyed in Part I sends both, and a model given
  only JSON produces tidy data and ugly drawings.

  ## Rendered by Quick Look, which is a real dependency and is written down

  There is no SVG rasteriser in this stack — no `rsvg-convert`, no `resvg`, no
  ImageMagick — and adding an image *decoder* to the BEAM to draw pictures the
  operator already has would be a large surface for a small feature. macOS ships
  `qlmanage`, whose SVG support is the same WebKit the app already embeds, and it
  was measured before being relied on: a 400x300 sketch came back rendered
  correctly, padded to a square because a thumbnailer boxes its output.

  **Three things that follows from, stated rather than discovered:**

  1. **The output is square-padded.** Harmless — the drawing is undistorted and
     the padding is empty — but it is why the PNG's dimensions are not the SVG's.
  2. **It is macOS-only.** So is the app (`minimumSystemVersion: 14.0`), so this
     costs nothing today and would cost a rewrite on the day that changes.
  3. **It has never run in a packaged build.** `qlmanage` is a developer utility
     and the hardened runtime has not been asked to spawn one. Until someone
     watches it work in the DMG, a failure here is expected rather than
     surprising — which is why it is non-fatal.

  ## Failure is never fatal

  `render/2` returns `{:error, reason}` and `sketch_get` returns the element list
  anyway. A read that fails because a *picture* could not be drawn would be worse
  than the missing picture: the model can still describe a sketch from its
  elements, and Phase 2's exit test only needs it to be right about what is there.

  ## Cached by content

  The PNG lands in the sketch's sidecar as `preview-<hash>.png`, hashed over the
  rendered SVG. An unchanged sketch re-uses it, a changed one renders once, and
  stale previews are swept on each render so the folder does not accumulate one
  per edit.
  """

  require Logger

  alias BusterClaw.Sketch.{Document, Paths, Svg}

  @renderer "/usr/bin/qlmanage"
  @size 1024
  @timeout_ms 15_000

  @doc "Whether a rasteriser is available at all."
  def available?, do: File.regular?(@renderer)

  @doc """
  Render `doc` to a PNG in its sidecar. `{:ok, path}` or `{:error, reason}`.

  `sketch` names the document so embedded images can be found.
  """
  def render(sketch, %Document{} = doc) do
    svg = Svg.to_document(doc, sketch: sketch)
    hash = :sha256 |> :crypto.hash(svg) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    with {:ok, dir} <- Paths.assets_dir(sketch) do
      target = Path.join(dir, "preview-#{hash}.png")

      if File.regular?(target) do
        {:ok, target}
      else
        produce(dir, svg, target, hash)
      end
    end
  end

  # --- internals ------------------------------------------------------------

  defp produce(dir, svg, target, hash) do
    if available?() do
      with :ok <- File.mkdir_p(dir),
           {:ok, svg_path} <- write_svg(dir, svg, hash),
           :ok <- rasterize(svg_path, dir),
           :ok <- adopt(svg_path, target) do
        sweep(dir, target)
        {:ok, target}
      end
    else
      {:error, :no_renderer}
    end
  end

  defp write_svg(dir, svg, hash) do
    path = Path.join(dir, "preview-#{hash}.svg")

    case File.write(path, svg) do
      :ok -> {:ok, path}
      {:error, _reason} -> {:error, :unwritable}
    end
  end

  # `qlmanage` writes `<name>.png` beside whatever it was pointed at, so the
  # output name is its choice rather than ours — hence `adopt/2` below.
  defp rasterize(svg_path, dir) do
    task =
      Task.async(fn ->
        System.cmd(@renderer, ["-t", "-s", Integer.to_string(@size), "-o", dir, svg_path],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Sketch.Preview: qlmanage exited #{status}: #{String.slice(output, 0, 200)}"
        )

        {:error, :render_failed}

      _ ->
        # A thumbnailer that hangs must not hang the command that asked for it.
        Logger.warning("Sketch.Preview: qlmanage timed out")
        {:error, :render_timeout}
    end
  end

  defp adopt(svg_path, target) do
    produced = svg_path <> ".png"

    # The SVG goes either way — it is an input to the render, not an artifact of
    # it, and leaving one behind on failure would put a file in the operator's
    # folder that nothing ever reads.
    _ = File.rm(svg_path)

    if File.regular?(produced) do
      case File.rename(produced, target) do
        :ok -> :ok
        {:error, _reason} -> {:error, :unwritable}
      end
    else
      {:error, :render_failed}
    end
  end

  # One preview per sketch, not one per edit. The current render is kept and
  # every other `preview-*` goes, including the `.svg` inputs of past runs.
  defp sweep(dir, keep) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "preview-"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reject(&(&1 == keep))
        |> Enum.each(&File.rm/1)

      _ ->
        :ok
    end
  end
end
