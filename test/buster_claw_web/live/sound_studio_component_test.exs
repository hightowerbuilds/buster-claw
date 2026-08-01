defmodule BusterClawWeb.SoundStudioComponentTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.StudioAudio
  alias BusterClawWeb.SoundStudioComponent

  setup do
    root = Path.join(System.tmp_dir!(), "bc_studio_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))
    File.mkdir_p!(Path.join([root, "sounds", "music"]))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp open_studio(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> element("button[phx-value-tab='studio']") |> render_click()
    {view, html}
  end

  defp select(view, id) do
    view |> element("button[phx-value-id='#{id}']") |> render_click()
  end

  describe "the tab" do
    test "opens — the select_home_tab guard is a whitelist, so this is not a formality",
         %{conn: conn} do
      {_view, html} = open_studio(conn)

      assert html =~ "Sounds"
      assert html =~ "Recordings"
      assert html =~ "Music"
      # The empty-selection invitation, not a blank panel.
      assert html =~ "Pick something on the left"
    end
  end

  describe "the sidebar" do
    test "lists the bundled chimes with no workspace library at all", %{conn: conn} do
      {_view, html} = open_studio(conn)

      for key <- ["confirm", "security", "boot"] do
        assert html =~ ~s(phx-value-id="sound:#{key}.wav"), "#{key} missing from the sidebar"
      end

      assert html =~ "bundled"
    end

    test "a workspace override is ONE entry, marked yours — not two", %{
      conn: conn,
      root: root
    } do
      File.write!(Path.join([root, "sounds", "confirm.wav"]), SoundGen.render("confirm"))

      {_view, html} = open_studio(conn)

      # The resolver plays exactly one of these; listing both would advertise a
      # choice that does not exist.
      occurrences =
        html |> String.split(~s(phx-value-id="sound:confirm.wav")) |> length() |> Kernel.-(1)

      assert occurrences == 1
      assert html =~ "yours"
    end

    test "the operator's own sounds are listed beside the built-ins", %{conn: conn, root: root} do
      File.write!(Path.join([root, "sounds", "bongos.wav"]), SoundGen.render("chat"))
      File.write!(Path.join([root, "sounds", "wilhelm.wav"]), SoundGen.render("chat"))

      {_view, html} = open_studio(conn)

      # A scream and a bongo hit are raw material, not clutter — the sidebar
      # once looked like a system dump because of phx.digest duplicates, not
      # because of files the operator put there on purpose.
      assert html =~ ~s(phx-value-id="sound:bongos.wav")
      assert html =~ ~s(phx-value-id="sound:wilhelm.wav")
      assert html =~ ~s(phx-value-id="sound:confirm.wav")
    end

    test "phx.digest's hashed copies are never listed as sounds", %{conn: conn} do
      {_view, html} = open_studio(conn)

      # `mix phx.digest` writes `alarm-<md5>.wav` beside `alarm.wav`. Listing
      # both doubled the routing menu and made the sidebar read as system junk.
      refute html =~ ~r/sound:[a-z]+-[0-9a-f]{32}\.wav/
    end
  end

  describe "putting our set on disk" do
    test "offers the copy only while chimes are missing, and never overwrites", %{
      conn: conn,
      root: root
    } do
      mine = Path.join([root, "sounds", "confirm.wav"])
      File.write!(mine, SoundGen.render("boot"))

      {view, html} = open_studio(conn)
      assert html =~ "Copy 15 built-in to sounds/"

      html = view |> element("button[phx-click='install_bundled']") |> render_click()

      # The operator's own confirm.wav is theirs — a restore must not clobber it.
      assert File.read!(mine) == SoundGen.render("boot")
      assert html =~ "Copied 15 into sounds/"
      # Nothing left to copy, so the affordance retires itself.
      refute html =~ "Copy 15 built-in"
      assert File.regular?(Path.join([root, "sounds", "alarm.wav"]))
    end

    test "is never automatic — ensure/0 must not seed the folder", %{root: root} do
      # SOUND_ROADMAP Part III rule 1: a boot-time copy resurrects files the
      # operator deleted, which is how "delete that sound" becomes a bug report.
      Sound.ensure()

      assert File.dir?(Path.join(root, "sounds"))
      refute File.exists?(Path.join([root, "sounds", "alarm.wav"]))
    end
  end

  describe "the detail pane" do
    test "opens a selection and reports facts read from the file, not the filename",
         %{conn: conn} do
      {view, _html} = open_studio(conn)
      html = select(view, "sound:security.wav")

      assert html =~ "security"
      # Real measurements: security.wav is ~1.01 s and peaks around -3.4 dBFS.
      assert html =~ "1.01 s"
      assert html =~ "22050 Hz"
      assert html =~ "dBFS"
    end

    test "the preview points at a route, never a blob: URL", %{conn: conn} do
      {view, _html} = open_studio(conn)
      html = select(view, "sound:boot.wav")

      # CSP has no media-src and falls back to default-src 'self', which excludes
      # blob: — a blob preview works in dev and fails only in the packaged app.
      assert html =~ ~s(src="/notify/sound/boot.wav")
      refute html =~ "blob:"
    end

    test "the waveform wears its source kind's color", %{conn: conn} do
      {view, _html} = open_studio(conn)

      # A chime is house hazard…
      html = select(view, "sound:boot.wav")
      assert html =~ ~s(data-color-a="#FF4D1C")
      assert html =~ ~s(data-color-b="#66210E")

      # …and an import is signal blue. The wave div is keyed by selection and
      # AudioClip reads its colors once at mount, so the remount IS the recolor
      # — same mechanism that keeps stale waveforms off screen.
      file =
        file_input(view, "#studio-import", :import, [
          %{name: "tint.wav", content: SoundGen.render("chat"), type: "audio/wav"}
        ])

      render_upload(file, "tint.wav")
      html = select(view, "import:tint.wav")

      assert html =~ ~s(data-color-a="#1C9BFF")
      assert html =~ ~s(data-color-b="#0B3E66")
      # The badge is the legend: the kind label wears the same color.
      assert html =~ ~s(color: #1C9BFF)
    end

    test "the waveform id is keyed by source, so switching files remounts the hook",
         %{conn: conn} do
      {view, _html} = open_studio(conn)

      boot = select(view, "sound:boot.wav")
      alarm = select(view, "sound:alarm.wav")

      boot_id = Regex.run(~r/id="(studio-wave-[^"]+)"/, boot) |> Enum.at(1)
      alarm_id = Regex.run(~r/id="(studio-wave-[^"]+)"/, alarm) |> Enum.at(1)

      # AudioClip decodes data-src exactly once, at mount. A shared id would
      # leave the first file's waveform on screen forever.
      assert boot_id && alarm_id
      refute boot_id == alarm_id
    end
  end

  describe "selection ownership (Part V landmine 2)" do
    test "survives leaving the tab and coming back", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:confirm.wav")

      # Home tabs render behind `:if`, which REMOVES the DOM and discards the
      # live_component with it. A selection held in the component would be gone
      # here — which is the failure that demos perfectly and loses real work.
      view |> element("button[phx-value-tab='chat']") |> render_click()
      html = view |> element("button[phx-value-tab='studio']") |> render_click()

      assert html =~ "confirm"
      assert html =~ ~s(aria-current="true")
    end
  end

  describe "the frosted panel" do
    test "carries ic-panel, which on the homepage is the translucent blur", %{conn: conn} do
      {_view, html} = open_studio(conn)

      # `.ic-home .ic-panel` is 70% base-100 + a 10px backdrop blur — the same
      # treatment the chat panel gets, so the smoke shader reads through.
      assert html =~ "ic-panel"
    end
  end

  describe "the tab bar toolbar" do
    test "New audio and Import audio ride the tab bar, only while the Studio is open",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # On Chat there is no Studio toolbar — the action slot belongs to the
      # active tab.
      refute html =~ "studio-toolbar"

      html = view |> element("button[phx-value-tab='studio']") |> render_click()
      assert html =~ "studio-toolbar"
      assert html =~ "New audio"
      assert html =~ "Import audio"
    end

    test "the toolbar's create form reaches the component through its selector target",
         %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      # The form lives OUTSIDE the live_component (in the tab bar row) and
      # addresses it via phx-target="#studio-panel". If that selector breaks,
      # submits raise instead of creating.
      view |> element("#studio-new-audio") |> render_submit(%{"name" => "from the bar"})
      html = render(view)

      assert File.regular?(
               Path.join([root, "sounds", "studio", "tracks", "from the bar.track.json"])
             )

      assert html =~ "from the bar"
      assert html =~ "Add clip"
    end
  end

  describe "importing" do
    test "offers a way in, and names where files land", %{conn: conn} do
      {_view, html} = open_studio(conn)

      assert html =~ "Import audio"
      assert html =~ "studio/"
      assert html =~ "Imports"
    end

    test "a chosen file lands in studio/ with no second submit click", %{
      conn: conn,
      root: root
    } do
      {view, _html} = open_studio(conn)

      file =
        file_input(view, "#studio-import", :import, [
          %{name: "clip.wav", content: SoundGen.render("chat"), type: "audio/wav"}
        ])

      # auto_upload: true — picking the file IS the import. The toolbar button
      # only opens the OS picker; there is nothing else to press.
      render_upload(file, "clip.wav")
      html = render(view)

      assert File.regular?(Path.join([root, "sounds", "studio", "clip.wav"]))
      assert html =~ "Imported clip.wav"
      assert html =~ ~s(phx-value-id="import:clip.wav")
    end

    test "a file that cannot be decoded is refused with a reason", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      file =
        file_input(view, "#studio-import", :import, [
          %{name: "prose.wav", content: "I am prose wearing a .wav extension", type: "audio/wav"}
        ])

      render_upload(file, "prose.wav")
      html = render(view)

      # The gate is a decode, not an extension — and it says so rather than
      # failing silently, naming the file since nothing else on screen does.
      assert html =~ "prose.wav"
      assert html =~ "couldn&#39;t be decoded" or html =~ "couldn't be decoded"
      refute File.regular?(Path.join([root, "sounds", "studio", "prose.wav"]))
    end

    test "an imported file is selectable and served from its own route", %{conn: conn} do
      {view, _html} = open_studio(conn)

      file =
        file_input(view, "#studio-import", :import, [
          %{name: "cut.wav", content: SoundGen.render("alarm"), type: "audio/wav"}
        ])

      render_upload(file, "cut.wav")

      html = select(view, "import:cut.wav")

      assert html =~ ~s(src="/studio/file/cut.wav")
      assert html =~ "1.32 s"
    end
  end

  describe "the trim tool" do
    # The hook pushes to StatusLive on pointerup; drive that directly, since a
    # pointer drag is the one part a LiveView test cannot perform.
    defp drag(view, from, to) do
      render_hook(view, "trim_select", %{"from_ms" => from, "to_ms" => to})
    end

    test "a selection shows its bounds and length", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")

      html = drag(view, 100, 400)

      assert html =~ "100 ms"
      assert html =~ "400 ms"
      # The length is the number that actually matters when cutting.
      assert html =~ "300 ms"
      assert html =~ "Trim to selection"
    end

    test "trimming writes a NEW file and leaves the original untouched", %{
      conn: conn,
      root: root
    } do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")
      drag(view, 0, 300)

      original = Path.join([root, "sounds", "alarm.wav"])
      before = File.exists?(original) && File.read!(original)

      html = view |> element("button[phx-click='apply_trim']") |> render_click()

      # Design rule 2: read-only in, new file out. An edit never touches its source.
      assert html =~ "Saved alarm-trim.wav"
      trimmed = Path.join([root, "sounds", "studio", "alarm-trim.wav"])
      assert File.regular?(trimmed)
      if before, do: assert(File.read!(original) == before)

      # And the result is what was asked for, to the sample.
      {:ok, clip} = SoundStudio.import_source(trimmed)
      assert_in_delta SoundStudio.duration_ms(clip), 300.0, 1.0
    end

    test "the result is opened, and the trim clears with it", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")
      drag(view, 0, 250)

      view |> element("button[phx-click='apply_trim']") |> render_click()
      html = render(view)

      # Landing on the new file is the only way to hear what you just made.
      assert html =~ ~s(phx-value-id="import:alarm-trim.wav")
      # The in/out points described the SOURCE; carrying them onto the result
      # would point at a waveform that no longer exists.
      refute html =~ "Trim to selection"
    end

    test "trimming twice keeps both takes", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      for _ <- 1..2 do
        select(view, "sound:alarm.wav")
        drag(view, 0, 200)
        view |> element("button[phx-click='apply_trim']") |> render_click()
      end

      assert File.regular?(Path.join([root, "sounds", "studio", "alarm-trim.wav"]))
      assert File.regular?(Path.join([root, "sounds", "studio", "alarm-trim-2.wav"]))
    end

    test "a trim does not survive changing the source", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")
      drag(view, 0, 200)

      html = select(view, "sound:boot.wav")

      # One file's in/out points applied to another's waveform is nonsense.
      refute html =~ "Trim to selection"
    end

    test "but it DOES survive leaving the tab (Part V landmine 2)", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")
      drag(view, 120, 480)

      view |> element("button[phx-value-tab='chat']") |> render_click()
      html = view |> element("button[phx-value-tab='studio']") |> render_click()

      # An in-progress edit must outlive a glance at Chat.
      assert html =~ "120 ms"
      assert html =~ "480 ms"
    end

    test "clearing drops the selection", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")
      drag(view, 0, 200)

      html = view |> element("button[phx-click='trim_clear']") |> render_click()

      refute html =~ "Trim to selection"
      assert html =~ "Drag across the waveform"
    end

    test "an inverted or empty drag is ignored rather than stored", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select(view, "sound:alarm.wav")

      html = drag(view, 400, 400)
      refute html =~ "Trim to selection"

      html = drag(view, 400, 100)
      refute html =~ "Trim to selection"
    end
  end

  describe "audio arrangements" do
    defp new_audio(view, name) do
      view |> element("#studio-new-audio") |> render_submit(%{"name" => name})
      # The component asks the parent to open the new audio via a message, so
      # the selection lands one render after the submit returns.
      render(view)
    end

    defp open_audio(view, name) do
      select(view, "audio:" <> name)
    end

    defp add_clip(view, source, track_index \\ 0) do
      track = view |> render() |> track_ids() |> Enum.at(track_index)

      view
      |> element("form[phx-submit='add_clip']")
      |> render_submit(%{"source" => source, "track" => track})
    end

    defp track_ids(html) do
      Regex.scan(~r/data-track-id="([^"]+)"/, html) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
    end

    defp clip_ids(html) do
      Regex.scan(~r/data-clip-id="([^"]+)"/, html) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
    end

    test "a new audio is created, saved, and opened", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      html = new_audio(view, "doorbell idea")

      assert File.regular?(
               Path.join([root, "sounds", "studio", "tracks", "doorbell idea.track.json"])
             )

      # Opened straight away — an audio you have to go find is an audio you
      # made by accident.
      assert html =~ "doorbell idea"
      assert html =~ "Add clip"
      assert length(track_ids(html)) == 1
      # The control cluster sits to the LEFT of the clip region, Pro Tools
      # style — the label lives there, not overlaid on the clips.
      assert html =~ "Track A"
    end

    test "a nameless audio is refused", %{conn: conn} do
      {view, _html} = open_studio(conn)

      html = new_audio(view, "   ")

      assert html =~ "Give the audio a name"
      assert StudioAudio.list() == []
    end

    test "clips are added to a chosen track and queue up rather than stacking", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "queue")

      add_clip(view, "sound:alarm.wav")
      html = add_clip(view, "sound:boot.wav")

      assert length(clip_ids(html)) == 2
      # alarm is 1.32 s, so boot lands after it rather than on top of it.
      assert html =~ "starts 0 ms"
      assert html =~ "starts 1.32 s"
    end

    test "tracks can be added and removed, and the last one stays", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "rows")

      html = view |> element("button[phx-click='add_track']") |> render_click()
      assert length(track_ids(html)) == 2
      assert html =~ "2 tracks"

      [_first, second] = track_ids(html)

      html =
        view
        |> element("button[phx-value-id='#{second}'][phx-click='remove_track']")
        |> render_click()

      assert length(track_ids(html)) == 1

      # An audio with no tracks has nothing to drop onto, so the button is gone.
      refute html =~ "phx-click=\"remove_track\""
    end

    test "a clip moves along its track and across tracks, staying ONE clip", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "move")
      view |> element("button[phx-click='add_track']") |> render_click()
      add_clip(view, "sound:boot.wav")

      html = render(view)
      [clip] = clip_ids(html)
      [_track_a, track_b] = track_ids(html)

      html =
        view
        |> element("[phx-hook='TrackArrange']")
        |> render_hook("move_clip", %{
          "clip_id" => clip,
          "track_id" => track_b,
          "start_ms" => 2_500
        })

      assert clip_ids(html) == [clip]
      assert html =~ "starts 2.5 s"
    end

    test "an arrangement survives leaving the tab — it was never only in memory", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "durable")
      add_clip(view, "sound:alarm.wav")

      view |> element("button[phx-value-tab='chat']") |> render_click()
      view |> element("button[phx-value-tab='studio']") |> render_click()
      html = open_audio(view, "durable")

      assert length(clip_ids(html)) == 1
    end

    test "rendering mixes every track into one file and opens it", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "mix me")
      view |> element("button[phx-click='add_track']") |> render_click()
      add_clip(view, "sound:alarm.wav", 0)
      add_clip(view, "sound:boot.wav", 1)

      html = view |> element("button[phx-click='render_audio']") |> render_click()

      assert html =~ "Rendered mix me-mix.wav"
      mixed = Path.join([root, "sounds", "studio", "mix me-mix.wav"])
      assert File.regular?(mixed)

      # Tracks SUM: both clips start at 0 on their own tracks, so the render is
      # as long as the longer one, not the two end to end.
      {:ok, clip} = SoundStudio.import_source(mixed)
      assert_in_delta SoundStudio.duration_ms(clip), 1_320.0, 20.0

      # And the result is opened, so you can hear what you just made.
      assert render(view) =~ ~s(phx-value-id="import:mix me-mix.wav")
    end

    test "rendering an empty audio says so instead of writing silence", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "empty")

      html = view |> element("button[phx-click='render_audio']") |> render_click()
      assert html =~ "Add a clip before rendering"
    end

    test "a clip whose source vanished fails the whole render, loudly", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "orphan")

      File.write!(Path.join([root, "sounds", "temp.wav"]), SoundGen.render("chat"))
      add_clip(view, "sound:temp.wav")
      File.rm!(Path.join([root, "sounds", "temp.wav"]))

      html = view |> element("button[phx-click='render_audio']") |> render_click()

      # A mix missing one layer still sounds finished — you would never know.
      assert html =~ "source is missing"
      refute File.regular?(Path.join([root, "sounds", "studio", "orphan-mix.wav"]))
    end

    test "deleting an audio leaves the clips it used alone", %{conn: conn, root: root} do
      keeper = Path.join([root, "sounds", "keeper.wav"])
      File.write!(keeper, SoundGen.render("chat"))

      {view, _html} = open_studio(conn)
      new_audio(view, "doomed")
      add_clip(view, "sound:keeper.wav")

      view |> element("button[phx-click='delete_audio']") |> render_click()

      refute File.exists?(Path.join([root, "sounds", "studio", "tracks", "doomed.track.json"]))
      # An audio is an arrangement OF clips, not a container holding them.
      assert File.regular?(keeper)
    end

    test "tracks carry their own colors, and a color survives its neighbor's death",
         %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "painted")

      view |> element("button[phx-click='add_track']") |> render_click()
      html = view |> element("button[phx-click='add_track']") |> render_click()

      # A (hazard), B (blue), C (green) — the eye follows material by color,
      # so siblings on one track must share one.
      assert html =~ "#FF4D1C"
      assert html =~ "#1C9BFF"
      assert html =~ "#2FD068"

      [_a, b, _c] = track_ids(html)

      html =
        view
        |> element("button[phx-value-id='#{b}'][phx-click='remove_track']")
        |> render_click()

      # Color hangs off the label letter, not the list position: deleting B
      # must NOT turn C blue. A track that changes color because a neighbor
      # died breaks exactly the visual memory the palette exists to serve.
      assert html =~ "Track C"
      assert html =~ "#2FD068"
      refute html =~ "#1C9BFF"
    end

    test "an audio cannot be added to an audio", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "outer")
      html = render(view)

      # The source picker offers material, not arrangements.
      refute html =~ ~s(<option value="audio:outer")
    end
  end

  describe "arranger keyboard actions" do
    defp start_audio(conn, name) do
      {view, _html} = open_studio(conn)
      view |> element("#studio-new-audio") |> render_submit(%{"name" => name})
      render(view)
      {view, name}
    end

    defp add(view, source) do
      track = view |> render() |> track_ids() |> hd()

      view
      |> element("form[phx-submit='add_clip']")
      |> render_submit(%{"source" => source, "track" => track})
    end

    defp keys(view), do: view |> element("#studio-keys")

    # A real click reaches the COMPONENT, because the arranger hook's element
    # carries phx-target — LiveView resolves a hook's pushEvent against it.
    # Addressing the LiveView directly (render_hook/3 on the view) skips that
    # and is exactly how "clicking a clip never selected it" went unnoticed.
    defp click_clip(view, clip_id) do
      view
      |> element("[phx-hook='TrackArrange']")
      |> render_hook("select_clip", %{"id" => clip_id})

      render(view)
    end

    test "clicking a clip selects it", %{conn: conn} do
      {view, _name} = start_audio(conn, "select")
      add(view, "sound:boot.wav")
      [clip] = view |> render() |> clip_ids()

      html = click_clip(view, clip)

      # The selected clip is the subject copy, paste, and delete act on, so it
      # has to be visibly distinct.
      assert html =~ "ring-2 ring-primary"
      assert keys(view) |> render() =~ ~s(data-clip-selected="true")
    end

    test "copy then paste duplicates a clip as its own clip", %{conn: conn} do
      {view, _name} = start_audio(conn, "dupe")
      add(view, "sound:boot.wav")
      [clip] = view |> render() |> clip_ids()

      click_clip(view, clip)
      render_hook(view, "studio_copy", %{})
      html = render_hook(view, "studio_paste", %{})

      ids = clip_ids(html)
      assert length(ids) == 2
      # A NEW id, not a second reference — a pasted copy must be movable and
      # deletable on its own.
      assert clip in ids
      assert html =~ "copied: boot.wav"
    end

    test "paste with an empty clipboard does nothing", %{conn: conn} do
      {view, _name} = start_audio(conn, "nothing")
      add(view, "sound:boot.wav")

      html = render_hook(view, "studio_paste", %{})
      assert length(clip_ids(html)) == 1
    end

    test "delete removes the selected clip — the only way to, until now", %{conn: conn} do
      {view, _name} = start_audio(conn, "cull")
      add(view, "sound:boot.wav")
      [clip] = view |> render() |> clip_ids()

      click_clip(view, clip)
      html = render_hook(view, "studio_delete_clip", %{})

      assert clip_ids(html) == []
      # Selection is dropped with it; a stale id would let the next delete act
      # on nothing.
      assert keys(view) |> render() =~ ~s(data-clip-selected="false")
    end

    test "undo walks back an add, and redo walks it forward", %{conn: conn, root: root} do
      {view, name} = start_audio(conn, "history")
      add(view, "sound:boot.wav")
      add(view, "sound:alarm.wav")
      assert length(clip_ids(render(view))) == 2

      html = render_hook(view, "studio_undo", %{})
      assert length(clip_ids(html)) == 1

      html = render_hook(view, "studio_undo", %{})
      assert clip_ids(html) == []

      html = render_hook(view, "studio_redo", %{})
      assert length(clip_ids(html)) == 1

      # Undo rewrites the file, not just the screen — the arrangement on disk is
      # the arrangement.
      {:ok, audio} = StudioAudio.load(name)
      assert length(StudioAudio.clips(audio)) == 1

      assert File.regular?(Path.join([root, "sounds", "studio", "tracks", name <> ".track.json"]))
    end

    test "undo covers moves and tracks, not just clips", %{conn: conn} do
      {view, _name} = start_audio(conn, "moves")
      view |> element("button[phx-click='add_track']") |> render_click()
      add(view, "sound:boot.wav")

      html = render(view)
      [clip] = clip_ids(html)
      [_a, track_b] = track_ids(html)

      view
      |> element("[phx-hook='TrackArrange']")
      |> render_hook("move_clip", %{"clip_id" => clip, "track_id" => track_b, "start_ms" => 3_000})

      assert render(view) =~ "starts 3.0 s"
      html = render_hook(view, "studio_undo", %{})
      assert html =~ "starts 0 ms"
    end

    test "undo and redo are disabled when there is nowhere to go", %{conn: conn} do
      {view, _name} = start_audio(conn, "edges")
      html = render(view)

      assert html =~ ~r/phx-click="studio_undo" disabled/
      assert html =~ ~r/phx-click="studio_redo" disabled/

      add(view, "sound:boot.wav")
      html = render(view)
      refute html =~ ~r/phx-click="studio_undo" disabled/
    end

    test "a new edit after undoing abandons the redo branch", %{conn: conn} do
      {view, _name} = start_audio(conn, "branch")
      add(view, "sound:boot.wav")
      render_hook(view, "studio_undo", %{})

      html = render(view)
      refute html =~ ~r/phx-click="studio_redo" disabled/

      add(view, "sound:alarm.wav")
      html = render(view)

      # The standard contract: keeping the branch would let redo overwrite work
      # done since the undo.
      assert html =~ ~r/phx-click="studio_redo" disabled/
    end

    test "history and clipboard survive leaving the tab", %{conn: conn} do
      {view, _name} = start_audio(conn, "durable keys")
      add(view, "sound:boot.wav")
      [clip] = view |> render() |> clip_ids()
      click_clip(view, clip)
      render_hook(view, "studio_copy", %{})

      view |> element("button[phx-value-tab='chat']") |> render_click()
      view |> element("button[phx-value-tab='studio']") |> render_click()
      html = select(view, "audio:durable keys")

      # An undo stack that evaporates on a glance at Chat reads as the feature
      # being broken — which is why it lives in StatusLive, not the component.
      assert html =~ "copied: boot.wav"
      refute html =~ ~r/phx-click="studio_undo" disabled/
    end

    test "switching audios drops the history rather than undoing into the wrong one",
         %{conn: conn} do
      {view, _name} = start_audio(conn, "first")
      add(view, "sound:boot.wav")

      view |> element("#studio-new-audio") |> render_submit(%{"name" => "second"})
      html = render(view)

      # Undoing into an arrangement you are no longer looking at is not undo.
      assert html =~ ~r/phx-click="studio_undo" disabled/
    end
  end

  describe "the music library manager" do
    test "keeps a home inside the Studio", %{conn: conn} do
      {view, _html} = open_studio(conn)
      html = select(view, SoundStudioComponent.music_library_id())

      # Upload/queue/delete did not disappear with the tab rename.
      assert html =~ "Add music"
    end
  end
end
