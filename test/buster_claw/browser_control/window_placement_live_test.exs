defmodule BusterClaw.BrowserControl.WindowPlacementLiveTest do
  @moduledoc """
  Keeping the engine's window out of the user's way without killing the mirror.

  Agent Mode is headful on purpose — checkout popups and native dialogs need a
  real window — but the mirror shows the page inside the app, so the real window
  should not sit on top of everything demanding attention.

  The tidy-looking option does not work: a **minimized** window stops
  compositing on macOS, so `Page.screencastFrame` dries up after one frame and
  the mirror freezes. Off-screen keeps rendering. That trade-off is the reason
  this file exists — it is not obvious from the API and it is easy to "tidy up"
  back into a broken state.

  Headful, so this opens a real window briefly. Excluded by default.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.{CDP, Session}

  @moduletag :browser_engine
  @moduletag timeout: 90_000

  setup do
    {:ok, browser} = BrowserControl.detect()
    profile = Path.join(System.tmp_dir!(), "wp-#{System.unique_integer([:positive])}")

    {:ok, session} =
      Session.start_link(browser_path: browser, profile_dir: profile, headless: false, id: "wp")

    :ok =
      Session.navigate(
        session,
        "data:text/html;base64," <>
          Base.encode64("<html><body style='background:#222'><h1>window</h1></body></html>")
      )

    # start_link/1 links the engine to the test process, so by the time on_exit
    # runs the session is already going down with it — stopping it again exits.
    # Cleanup is best-effort; the engine's own terminate/2 reaps the OS process.
    on_exit(fn ->
      if Process.alive?(session) do
        try do
          Session.stop(session)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(profile)
    end)

    %{session: session}
  end

  defp left(session) do
    {:ok, %{"windowId" => wid}} = Session.command(session, "Browser.getWindowForTarget", %{})
    {:ok, cdp, _sid} = Session.handles(session)
    {:ok, %{"bounds" => b}} = CDP.command(cdp, "Browser.getWindowBounds", %{"windowId" => wid})
    b["left"]
  end

  test "stash pushes the window aside; reveal brings it back", %{session: session} do
    assert left(session) > -100, "a fresh window should launch on-screen"

    BrowserControl.stash_window(session)
    Process.sleep(400)
    stashed = left(session)

    # macOS clamps to keep a window reachable, so this will not be -32000 —
    # asserting "well off to the left" rather than an exact value, which is the
    # honest contract.
    assert stashed < -500, "window was not moved aside (left=#{stashed})"

    BrowserControl.reveal_window(session)
    Process.sleep(400)
    assert left(session) > 0, "reveal must put the window back on-screen"
  end

  test "a stashed window still composites — the mirror must not freeze", %{session: session} do
    BrowserControl.stash_window(session)
    Process.sleep(400)

    {:ok, cdp, sid} = Session.handles(session)
    :ok = CDP.subscribe(cdp, methods: ["Page.screencastFrame"])
    CDP.command(cdp, "Page.enable", %{}, session_id: sid)

    # Something that keeps repainting, so frames depend on compositing rather
    # than on a one-off paint.
    Session.command(session, "Runtime.evaluate", %{
      "expression" =>
        "setInterval(function(){document.body.style.background='#'+Math.floor(Math.random()*16777215).toString(16)},100)"
    })

    CDP.command(
      cdp,
      "Page.startScreencast",
      %{"format" => "jpeg", "quality" => 50, "maxWidth" => 640, "maxHeight" => 480},
      session_id: sid
    )

    frames =
      Enum.reduce_while(1..3, 0, fn _, acc ->
        receive do
          {:browser_control_event, "Page.screencastFrame", p, _} ->
            CDP.command(cdp, "Page.screencastFrameAck", %{"sessionId" => p["sessionId"]},
              session_id: sid
            )

            {:cont, acc + 1}
        after
          6_000 -> {:halt, acc}
        end
      end)

    assert frames >= 3,
           "only #{frames} frame(s) while stashed — compositing stopped, so the mirror would freeze"
  end
end
