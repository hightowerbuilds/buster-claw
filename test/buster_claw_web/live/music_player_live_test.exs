defmodule BusterClawWeb.MusicPlayerLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Music.Player

  setup do
    root = Path.join(System.tmp_dir!(), "bc_mplive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "sounds", "music"]))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    for name <- ["Artist - One.mp3", "Artist - Two.mp3", "Three.mp3"] do
      File.write!(Path.join([root, "sounds", "music", name]), "ID3fake")
    end

    {:ok, root: root}
  end

  defp player(conn) do
    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.MusicPlayerLive)
    view
  end

  describe "the idle dock" do
    test "renders the audio element but no transport", %{conn: conn} do
      html = render(player(conn))

      # The element exists from the start so the hook has something to own; it
      # is the CONTROLS that stay hidden until there is something to control.
      assert html =~ ~s(id="bc-music-audio")
      refute html =~ "aria-label=\"Pause\""
      refute html =~ "aria-label=\"Play\""
    end

    test "carries no src when nothing is loaded", %{conn: conn} do
      html = render(player(conn))
      refute html =~ "/music/track/"
    end
  end

  describe "playing" do
    test "a play command loads the track and shows transport", %{conn: conn} do
      view = player(conn)

      Player.request_play("Artist - One.mp3")
      html = render(view)

      assert html =~ "/music/track/Artist%20-%20One.mp3"
      assert html =~ ~s(data-playing="true")
      # Filename metadata reaches the dock label.
      assert html =~ "Artist — One"
      assert html =~ "aria-label=\"Pause\""
    end

    test "toggle pauses without unloading the track", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")

      html = view |> element("button[aria-label='Pause']") |> render_click()

      assert html =~ ~s(data-playing="false")
      assert html =~ "/music/track/Artist%20-%20One.mp3"
      assert html =~ "aria-label=\"Play\""
    end

    test "a queue shows its depth", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")
      Player.request_enqueue("Artist - Two.mp3")

      assert render(view) =~ "+1"
    end
  end

  describe "the element reporting back" do
    test "ended advances to the next queued track", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")
      Player.request_enqueue("Artist - Two.mp3")

      html = render_hook(view, "ended", %{})

      assert html =~ "Artist — Two"
      assert html =~ ~s(data-playing="true")
    end

    test "ending the last track clears the player rather than freezing on it", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")

      html = render_hook(view, "ended", %{})

      refute html =~ "/music/track/"
      assert html =~ ~s(data-playing="false")
    end

    test "an error on one track moves to the next instead of stalling", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")
      Player.request_enqueue("Artist - Two.mp3")

      html = render_hook(view, "error", %{"src" => "whatever"})

      assert html =~ "Artist — Two"
    end

    test "an error announces the failed name so the tab can say so", %{conn: conn} do
      Player.subscribe_state()
      view = player(conn)
      Player.request_play("Artist - One.mp3")

      render_hook(view, "error", %{"src" => "whatever"})

      assert_receive {:music_state, %Player{last_error: "Artist - One.mp3"}}
    end

    test "a refused autoplay corrects the UI instead of lying about it", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")

      html = render_hook(view, "playing", %{"playing" => false})

      assert html =~ ~s(data-playing="false")
      assert html =~ "aria-label=\"Play\""
    end

    test "position reports do not disturb the loaded track", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")

      html = render_hook(view, "position", %{"seconds" => 42.5})

      assert html =~ "/music/track/Artist%20-%20One.mp3"
      assert html =~ ~s(data-playing="true")
    end
  end

  describe "seeking" do
    test "each seek bumps the id so the client acts on a repeat", %{conn: conn} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")

      Player.request_seek(30)
      first = seek_id(render(view))

      Player.request_seek(30)
      second = seek_id(render(view))

      assert second == first + 1
    end
  end

  describe "announcements" do
    test "state changes reach subscribers so a tab can render transport", %{conn: conn} do
      Player.subscribe_state()
      _view = player(conn)

      Player.request_play("Artist - One.mp3")

      assert_receive {:music_state, %Player{track: "Artist - One.mp3", playing?: true}}
    end
  end

  describe "a deleted file" do
    test "is pruned from the queue rather than stranding it", %{conn: conn, root: root} do
      view = player(conn)
      Player.request_play("Artist - One.mp3")
      Player.request_enqueue("Artist - Two.mp3")

      # The user deletes it in Finder mid-session.
      File.rm!(Path.join([root, "sounds", "music", "Artist - Two.mp3"]))

      html = render_hook(view, "ended", %{})

      # Nothing left to play, and no attempt to load the missing file.
      refute html =~ "Artist%20-%20Two"
      assert html =~ ~s(data-playing="false")
    end
  end

  defp seek_id(html) do
    [[_, id]] = Regex.scan(~r/data-seek-id="(\d+)"/, html)
    String.to_integer(id)
  end
end
