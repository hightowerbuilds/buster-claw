defmodule BusterClaw.BrowserControl.ScreencastLiveTest do
  @moduledoc """
  The mirror against a REAL engine: frames actually arrive, they are real JPEGs,
  and the caster's lifecycle does what it claims.

  This has to be a live test. The whole feature is a CDP conversation —
  `Page.startScreencast`, `Page.screencastFrame`, `Page.screencastFrameAck` —
  and a stub proves only that we send the strings we decided to send. The 07-25
  lesson applies directly: a capability tested in isolation is not a capability.

  Excluded by default; run with `mix test --include browser_engine`.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.{Pool, Screencast, Session}

  @moduletag :browser_engine
  @moduletag timeout: 90_000

  # A page that repaints continuously, so the compositor keeps producing frames.
  #
  # Base64, not percent-encoding: `URI.encode/1` leaves `#` alone, so a plain
  # `data:text/html,` URL silently truncates at the first CSS colour and the
  # page arrives without its script. That cost an hour — it looks exactly like
  # "screencast only ever sends one frame", because a static page genuinely
  # only paints once.
  @animated_page """
  <html><body style="background:#121212;color:#F4F1EA;font-size:48px">
  <h1 id="tick">0</h1>
  <script>
    var n = 0;
    setInterval(function () {
      n++;
      document.getElementById('tick').textContent = n;
      document.body.style.background =
        '#' + Math.floor(Math.random() * 16777215).toString(16);
    }, 100);
  </script>
  </body></html>
  """

  defp data_url(html), do: "data:text/html;base64," <> Base.encode64(html)

  setup do
    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 60_000)
    {:ok, session} = Pool.checkout(pool)
    :ok = Session.navigate(session, data_url(@animated_page))

    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    %{session: session}
  end

  defp await_frame(run_id, tries \\ 60) do
    cond do
      tries <= 0 -> nil
      frame = Screencast.latest(run_id) -> frame
      true -> Process.sleep(100) && await_frame(run_id, tries - 1)
    end
  end

  test "frames arrive from a real engine and decode as JPEG", %{session: session} do
    run_id = "mirror_live_1"
    assert {:ok, caster} = Screencast.watch(run_id, session)
    assert Process.alive?(caster)

    assert base64 = await_frame(run_id), "no screencast frame arrived from the engine"
    assert {:ok, jpeg} = Base.decode64(base64)

    # JPEG SOI marker — proof this is an image, not just a non-empty string.
    assert <<0xFF, 0xD8, _rest::binary>> = jpeg
    assert byte_size(jpeg) > 1_000

    Screencast.stop(run_id)
  end

  test "the ack keeps frames flowing — a stalled ack would stop at one", %{session: session} do
    run_id = "mirror_live_2"
    {:ok, caster} = Screencast.watch(run_id, session)

    Screencast.subscribe(run_id)

    # Chromium withholds the next frame until the current one is acked, so
    # receiving several in a row IS the proof that acking works. Without it this
    # test would time out after exactly one frame.
    for n <- 1..3 do
      assert_receive {:screencast_frame, ^run_id, _data}, 15_000, "stalled after #{n - 1} frames"
    end

    assert %{frames: frames} = GenServer.call(caster, :stats)
    assert frames >= 3

    Screencast.stop(run_id)
  end

  test "a second watcher joins the same caster rather than starting a rival", %{session: session} do
    run_id = "mirror_live_3"
    {:ok, first} = Screencast.watch(run_id, session)

    # The watcher must OUTLIVE the call — the caster monitors the calling
    # process, so a Task that returns immediately is already gone by the time
    # the count is read.
    me = self()

    second_watcher =
      spawn(fn ->
        send(me, {:watched, Screencast.watch(run_id, session)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:watched, {:ok, second}}, 5_000
    assert first == second
    assert %{watchers: 2} = GenServer.call(first, :stats)

    send(second_watcher, :stop)
    Screencast.stop(run_id)
  end

  test "the caster stops once the last watcher goes away", %{session: session} do
    run_id = "mirror_live_4"

    watcher =
      spawn(fn ->
        Screencast.watch(run_id, session)
        receive do: (:never -> :ok)
      end)

    Process.sleep(500)
    caster = Screencast.whereis(run_id)
    assert is_pid(caster)

    ref = Process.monitor(caster)
    Process.exit(watcher, :kill)

    # Lingers briefly (a reload re-watches), then stops on its own.
    assert_receive {:DOWN, ^ref, :process, ^caster, _}, 15_000

    # Registry cleanup rides its own monitor, so it is not ordered against ours
    # — poll rather than assert on the instant after :DOWN.
    assert eventually(fn -> Screencast.whereis(run_id) == nil end),
           "the caster stayed registered after it died"
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "an unwatched run costs nothing — no caster exists until asked" do
    assert Screencast.whereis("never_watched") == nil
    assert Screencast.latest("never_watched") == nil
  end

  test "a STATIC page still produces a frame — the mirror never opens blank", %{
    session: session
  } do
    # The bug this pins was invisible to every unit test and only showed up in
    # the end-to-end walk: a screencast emits on *new compositor frames*, so a
    # page that has finished painting sends nothing at all. Since the agent
    # usually pauses on a settled page, the common case was a permanently black
    # panel that looked like a broken mirror rather than a still page.
    :ok =
      Session.navigate(
        session,
        data_url("<html><body style='background:#eee'><h1>Static</h1></body></html>")
      )

    run_id = "mirror_static"
    {:ok, _} = Screencast.watch(run_id, session)

    assert base64 = await_frame(run_id), "a settled page must still seed a frame"
    assert {:ok, <<0xFF, 0xD8, _::binary>>} = Base.decode64(base64)

    Screencast.stop(run_id)
  end
end
