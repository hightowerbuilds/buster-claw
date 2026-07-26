defmodule BusterClawWeb.AgentViewController do
  @moduledoc """
  The mirror's transport (BROWSER_ENGINE_ROADMAP Phase 7): an Agent Mode run's
  viewport as MJPEG, rendered by a plain `<img>`.

  `multipart/x-mixed-replace` is an old trick and the right one here. The webview
  decodes natively, there is no JS on the hot path, and the frames never touch
  the LiveView channel — pushing base64 through `push_event` at 1280×900/q60/15fps
  is roughly 0.5–1 MB/s of JSON contending with every other diff on that socket,
  for a picture the browser can already decode by itself.

  Loopback-only, like the sibling `/browser` and `/ws` scopes. The stream carries
  a rendered page the user is already watching in a window on their own machine.

  The connection process is the watcher: `Screencast.watch/3` monitors it, so
  closing the tab (or navigating away) drops the last watcher and the caster
  stops on its own. No teardown call to forget.
  """
  use BusterClawWeb, :controller

  require Logger

  alias BusterClaw.BrowserControl.{AgentMode, Screencast}

  @boundary "busterclawframe"
  # A ceiling, not a target: the engine paces us by withholding the next frame
  # until its ack. This only bounds a pathological fast-frame case.
  @min_frame_interval_ms 40
  @idle_timeout_ms 30_000

  def show(conn, %{"run_id" => run_id}) do
    case AgentMode.whereis(run_id) do
      nil ->
        conn |> put_status(:not_found) |> text("no such run")

      run ->
        case Screencast.watch(run_id, AgentMode.session(run)) do
          {:ok, _caster} ->
            stream(conn, run_id)

          {:error, reason} ->
            conn |> put_status(:conflict) |> text("screencast: #{inspect(reason)}")
        end
    end
  end

  defp stream(conn, run_id) do
    Screencast.subscribe(run_id)

    conn =
      conn
      |> put_resp_header("content-type", "multipart/x-mixed-replace; boundary=#{@boundary}")
      |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate")
      |> put_resp_header("pragma", "no-cache")
      |> send_chunked(200)

    # Seed with whatever is already captured so the panel paints immediately
    # rather than staying blank until the page next repaints — an idle page may
    # not produce a frame for a long time.
    conn =
      case Screencast.latest(run_id) do
        nil -> conn
        frame -> push_frame(conn, frame)
      end

    loop(conn, run_id, 0)
  end

  defp loop(conn, run_id, last_sent_ms) do
    receive do
      {:screencast_frame, ^run_id, data} ->
        elapsed = System.monotonic_time(:millisecond) - last_sent_ms

        if elapsed < @min_frame_interval_ms do
          # Drop, never buffer. A viewer that cannot keep up should see older
          # frames skipped, not a queue growing behind it.
          loop(conn, run_id, last_sent_ms)
        else
          case push_frame_result(conn, data) do
            {:ok, conn} -> loop(conn, run_id, System.monotonic_time(:millisecond))
            {:error, _closed} -> conn
          end
        end
    after
      @idle_timeout_ms ->
        # Nothing painted in 30s. Ending the response lets the <img> reconnect,
        # which is also how a dead caster gets noticed.
        conn
    end
  end

  defp push_frame(conn, data) do
    case push_frame_result(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp push_frame_result(conn, base64) do
    case encode_part(base64) do
      nil -> {:ok, conn}
      part -> chunk(conn, part)
    end
  end

  @doc """
  One multipart frame: boundary, headers, raw JPEG bytes.

  Public because it is the actual contract with the `<img>` element and deserves
  a test that does not need a browser. `Content-Length` in particular is
  load-bearing — get it wrong and the image element waits forever on a part,
  which on screen is indistinguishable from the agent having frozen.

  Returns `nil` for undecodable data so a single corrupt frame is skipped rather
  than taking down a stream the user is actively watching.
  """
  def encode_part(base64) do
    case Base.decode64(base64) do
      {:ok, jpeg} ->
        IO.iodata_to_binary([
          "--",
          @boundary,
          "\r\n",
          "Content-Type: image/jpeg\r\n",
          "Content-Length: ",
          Integer.to_string(byte_size(jpeg)),
          "\r\n\r\n",
          jpeg,
          "\r\n"
        ])

      :error ->
        nil
    end
  end
end
