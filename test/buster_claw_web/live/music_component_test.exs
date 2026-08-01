defmodule BusterClawWeb.MusicComponentTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Music
  alias BusterClaw.Music.Player
  alias BusterClawWeb.SoundStudioComponent

  setup do
    root = Path.join(System.tmp_dir!(), "bc_musictab_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "music"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp add(root, name, contents \\ "ID3fake-payload") do
    File.write!(Path.join([root, "music", name]), contents)
  end

  # The Music tab became the Studio (SOUND_STUDIO_ROADMAP Phase 3). The library
  # manager kept every affordance it had, one level in: open the Studio, then
  # pick the manager entry at the top of the Music group.
  defp open_music(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-value-tab='studio']") |> render_click()

    html =
      view
      |> element("button[phx-value-id='#{SoundStudioComponent.music_library_id()}']")
      |> render_click()

    {view, html}
  end

  describe "the tab itself" do
    test "is offered on the homepage as the Studio", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Studio"
      assert html =~ ~s(phx-value-tab="studio")
      refute html =~ ~s(phx-value-tab="music")
    end

    test "opens — the select_home_tab guard is a whitelist, so this is not a formality",
         %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {_view, html} = open_music(conn)

      # Missing the guard entry would leave the click a silent no-op: the tab
      # button would highlight nothing and the panel would never appear.
      assert html =~ "Add music"
      assert html =~ "One"
    end
  end

  describe "the library listing" do
    test "shows what is on disk, split into title and artist", %{conn: conn, root: root} do
      add(root, "Miles Davis - So What.mp3")

      {_view, html} = open_music(conn)

      assert html =~ "So What"
      assert html =~ "Miles Davis"
    end

    test "reports the count and total size", %{conn: conn, root: root} do
      add(root, "a.mp3", String.duplicate("x", 2048))
      add(root, "b.mp3", String.duplicate("x", 2048))

      {_view, html} = open_music(conn)

      assert html =~ "2 tracks"
      assert html =~ "4.0 KB"
    end

    test "ignores non-audio sitting in the folder", %{conn: conn, root: root} do
      add(root, "song.mp3")
      File.write!(Path.join([root, "music", "README.md"]), "# Music")

      {_view, html} = open_music(conn)

      assert html =~ "1 track"
      refute html =~ "README"
    end
  end

  describe "the empty library" do
    test "reads as an invitation rather than a bug", %{conn: conn} do
      {_view, html} = open_music(conn)

      assert html =~ "No music yet"
      # It names the folder, because the library is a real directory the user
      # can fill from Finder too.
      assert html =~ "music/"
      assert html =~ "Artist - Title.mp3"
      # And the way in is still present.
      assert html =~ "Add music"
    end
  end

  describe "driving the dock player" do
    test "clicking a track commands the player rather than playing locally",
         %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")
      Player.subscribe_commands()

      {view, _html} = open_music(conn)
      view |> element("button[aria-label='Play One']") |> render_click()

      # The tab broadcasts; the sticky dock player is what actually plays.
      assert_receive {:music_command, {:play, "Artist - One.mp3"}}
    end

    test "+queue enqueues without interrupting", %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")
      Player.subscribe_commands()

      {view, _html} = open_music(conn)
      view |> element("button[phx-click='enqueue']") |> render_click()

      assert_receive {:music_command, {:enqueue, "Artist - One.mp3"}}
    end

    test "play all starts the first and queues the rest, in order",
         %{conn: conn, root: root} do
      add(root, "a - one.mp3")
      add(root, "b - two.mp3")
      add(root, "c - three.mp3")
      Player.subscribe_commands()

      {view, _html} = open_music(conn)
      view |> element("button[phx-click='play_all']") |> render_click()

      assert_receive {:music_command, {:play, "a - one.mp3"}}
      assert_receive {:music_command, {:enqueue, "b - two.mp3"}}
      assert_receive {:music_command, {:enqueue, "c - three.mp3"}}
    end
  end

  describe "reflecting transport it does not own" do
    test "marks the loaded track and shows queued ones", %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")
      add(root, "Artist - Two.mp3")

      {view, _html} = open_music(conn)

      # The dock player announces; the tab renders what it was told.
      Player.new()
      |> Player.play("Artist - One.mp3")
      |> Player.enqueue("Artist - Two.mp3")
      |> Player.announce()

      html = render(view)

      assert html =~ "queued"
      assert html =~ "Pause"
    end

    test "shows Resume when the player is paused elsewhere", %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {view, _html} = open_music(conn)

      Player.new()
      |> Player.play("Artist - One.mp3")
      |> Player.toggle()
      |> Player.announce()

      assert render(view) =~ "Resume"
    end

    test "renders a library with no transport before the player has spoken",
         %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {_view, html} = open_music(conn)

      # player is nil at this point; the list must still render rather than
      # crashing on a missing struct.
      assert html =~ "One"
      refute html =~ "queued"
    end
  end

  describe "the now-playing strip (Phase 5)" do
    test "renders the waveform container with its fallback when a track is loaded",
         %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {view, _html} = open_music(conn)

      Player.new() |> Player.play("Artist - One.mp3") |> Player.announce()
      html = render(view)

      assert html =~ "Now playing"
      # The AudioClip contract: hook + canvas + CSS fallback, so no WebGPU /
      # fetch / decode failure can leave a broken canvas.
      assert html =~ ~s(phx-hook="AudioClip")
      assert html =~ "data-clip-canvas"
      assert html =~ "data-clip-fallback"
      assert html =~ "/music/track/Artist%20-%20One.mp3"
    end

    test "the strip disappears when the player stops", %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {view, _html} = open_music(conn)

      Player.new() |> Player.play("Artist - One.mp3") |> Player.announce()
      assert render(view) =~ "Now playing"

      Player.new() |> Player.play("Artist - One.mp3") |> Player.stop() |> Player.announce()
      refute render(view) =~ "Now playing"
    end

    test "a remount happens on track change — the id is keyed by the track",
         %{conn: conn, root: root} do
      add(root, "a.mp3")
      add(root, "b.mp3")

      {view, _html} = open_music(conn)

      Player.new() |> Player.play("a.mp3") |> Player.announce()
      first = render(view)
      Player.new() |> Player.play("b.mp3") |> Player.announce()
      second = render(view)

      # phx-update="ignore" means only a NEW id remounts the hook, and the hook
      # decodes data-src exactly once, at mount — same id would freeze the wave
      # on the first track forever.
      [id_a] = Regex.run(~r/id="(music-wave-\d+)"/, first, capture: :all_but_first)
      [id_b] = Regex.run(~r/id="(music-wave-\d+)"/, second, capture: :all_but_first)
      assert id_a != id_b
    end

    test "names the /split limitation instead of letting it read as a bug",
         %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {view, _html} = open_music(conn)
      Player.new() |> Player.play("Artist - One.mp3") |> Player.announce()

      assert render(view) =~ "Split view has no dock"
    end

    test "a skipped track is named, not silently dropped", %{conn: conn, root: root} do
      add(root, "good.mp3")

      {view, _html} = open_music(conn)

      Player.new()
      |> Player.play("bad.mp3")
      |> Player.enqueue("good.mp3")
      |> Player.fail_current()
      |> Player.announce()

      html = render(view)

      # Apostrophes render escaped, so assert around them.
      assert html =~ "play bad.mp3 — skipped"
    end
  end

  describe "deleting" do
    test "removes the file and refreshes the list", %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {view, _html} = open_music(conn)
      html = view |> element("button[phx-click='delete']") |> render_click()

      assert html =~ "Deleted"
      assert html =~ "No music yet"
      assert Music.list() == []
    end

    test "asks first", %{conn: conn, root: root} do
      add(root, "Artist - One.mp3")

      {_view, html} = open_music(conn)

      # data-claw-confirm is the house replacement for LiveView's data-confirm.
      assert html =~ "data-claw-confirm"
    end
  end

  describe "uploading" do
    test "stores a chosen file into the library", %{conn: conn} do
      {view, _html} = open_music(conn)

      upload =
        file_input(view, "#music-upload", :track, [
          %{name: "Sigur Rós - Hoppípolla.mp3", content: "ID3real-enough", type: "audio/mpeg"}
        ])

      render_upload(upload, "Sigur Rós - Hoppípolla.mp3")
      html = view |> element("#music-upload") |> render_submit()

      assert html =~ "Added 1 track"
      assert Music.list() == ["Sigur Rós - Hoppípolla.mp3"]
      # The Phase 0 convention survived the Phase 2 sanitizer end-to-end.
      assert html =~ "Hoppípolla"
      assert html =~ "Sigur Rós"
    end

    test "a non-audio file wearing .mp3 is refused with a reason", %{conn: conn} do
      {view, _html} = open_music(conn)

      upload =
        file_input(view, "#music-upload", :track, [
          %{name: "not-music.mp3", content: "%PDF-1.7 this is a document", type: "audio/mpeg"}
        ])

      render_upload(upload, "not-music.mp3")
      html = view |> element("#music-upload") |> render_submit()

      # Apostrophes render escaped (isn&#39;t), so assert on a plain substring.
      assert html =~ "audio, whatever it is named"
      assert Music.list() == []
    end

    test "submitting with nothing chosen says so", %{conn: conn} do
      {view, _html} = open_music(conn)

      html = view |> element("#music-upload") |> render_submit()

      assert html =~ "Choose an audio file first"
    end

    test "two files with the same name both survive", %{conn: conn} do
      {view, _html} = open_music(conn)

      for _ <- 1..2 do
        upload =
          file_input(view, "#music-upload", :track, [
            %{name: "song.mp3", content: "ID3payload", type: "audio/mpeg"}
          ])

        render_upload(upload, "song.mp3")
        view |> element("#music-upload") |> render_submit()
      end

      assert Music.list() == ["song-2.mp3", "song.mp3"]
    end
  end
end
