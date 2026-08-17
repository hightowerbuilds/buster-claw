defmodule BusterClawWeb.SoundStudioComponentTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.StudioMix
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
    # /studio since 08-16 — was a Home sub-tab click.
    {:ok, view, html} = live(conn, ~p"/studio")
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

    test "marks only the operator's own files deletable for the context menu",
         %{conn: conn, root: root} do
      studio_dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(studio_dir)
      File.write!(Path.join(studio_dir, "mine.wav"), SoundGen.render("chat"))

      {_view, html} = open_studio(conn)

      # An import is yours; a bundled chime has no workspace file to delete.
      assert html =~
               ~s(data-studio-source="import:mine.wav" data-source-label="mine" data-deletable)

      assert html =~ ~s(data-studio-source="sound:confirm.wav")

      refute html =~
               ~s(data-studio-source="sound:confirm.wav" data-source-label="confirm" data-deletable)
    end

    test "a file over the decode cap still shows length and format, via the header probe",
         %{conn: conn, root: root} do
      # ~3.4 minutes of internal-format silence — over the 8 MB inline-decode
      # cap, exactly the shape of the packaged-walk report: a 20-minute import
      # whose facts came back all-nil. Only peak may go unmeasured; length and
      # format read from the header, and the trim tool keeps its duration.
      data_bytes = 9_000_000
      big = %SoundStudio{data: <<0::size(data_bytes * 8)>>}
      studio_dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(studio_dir)
      File.write!(Path.join(studio_dir, "long.wav"), SoundStudio.render(big))

      {view, _html} = open_studio(conn)
      html = select(view, "import:long.wav")

      expected_ms = data_bytes / 2 / 22_050 * 1000

      assert [duration] =
               Regex.run(~r/data-duration-ms="([\d.]+)"/, html, capture: :all_but_first)

      assert_in_delta String.to_float(duration), expected_ms, 100.0

      assert html =~ "Too large to decode inline — peak unmeasured."
      refute html =~ "This file&#39;s length is unknown"
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

      # Sub-tabs render behind `:if`, which REMOVES the DOM and discards the
      # live_component with it. A selection held in the component would be gone
      # here — the failure that demos perfectly and loses real work.
      #
      # This was a Home tab switch until 08-16. The Studio moved to `/studio`,
      # and the hazard came with it unchanged: `StudioPanel` dispatches behind
      # `:if` exactly as Home did, so leaving for Voice and returning to Mix
      # destroys and rebuilds the component the same way.
      view |> element("button[phx-value-tab='voice']") |> render_click()
      html = view |> element("button[phx-value-tab='mix']") |> render_click()

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
    test "New mix and Import audio ride the tab bar, only while the Studio is open",
         %{conn: conn} do
      # Was a Home tab switch until 08-16. The toolbar now rides `/studio`'s own
      # header and belongs to Mix specifically, so the thing it must not do is
      # follow you to another sub-tab.
      {:ok, view, html} = live(conn, ~p"/studio")

      assert html =~ "studio-toolbar"
      assert html =~ "New mix"
      assert html =~ "Import audio"

      html = view |> element("button[phx-value-tab='voice']") |> render_click()
      refute html =~ "studio-toolbar"
    end

    test "the toolbar's create form reaches the component through its selector target",
         %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      # The form lives OUTSIDE the live_component (in the tab bar row) and
      # addresses it via phx-target="#studio-panel". If that selector breaks,
      # submits raise instead of creating.
      view |> element("#studio-new-mix") |> render_submit(%{"name" => "from the bar"})
      html = render(view)

      assert File.regular?(
               Path.join([root, "sounds", "studio", "mixes", "from the bar.mix.json"])
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

      view |> element("button[phx-value-tab='voice']") |> render_click()
      html = view |> element("button[phx-value-tab='mix']") |> render_click()

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

  describe "mixes" do
    defp new_audio(view, name) do
      view |> element("#studio-new-mix") |> render_submit(%{"name" => name})
      # The component asks the parent to open the new audio via a message, so
      # the selection lands one render after the submit returns.
      render(view)
    end

    defp open_audio(view, name) do
      select(view, "mix:" <> name)
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

    test "a new mix is created, saved, and opened", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      html = new_audio(view, "doorbell idea")

      assert File.regular?(
               Path.join([root, "sounds", "studio", "mixes", "doorbell idea.mix.json"])
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

    test "a nameless mix is refused", %{conn: conn} do
      {view, _html} = open_studio(conn)

      html = new_audio(view, "   ")

      assert html =~ "Give the mix a name"
      assert StudioMix.list() == []
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

      view |> element("button[phx-value-tab='voice']") |> render_click()
      view |> element("button[phx-value-tab='mix']") |> render_click()
      html = open_audio(view, "durable")

      assert length(clip_ids(html)) == 1
    end

    test "rendering mixes every track into one file and opens it", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "mix me")
      view |> element("button[phx-click='add_track']") |> render_click()
      add_clip(view, "sound:alarm.wav", 0)
      add_clip(view, "sound:boot.wav", 1)

      html = view |> element("button[phx-click='render_mix']") |> render_click()

      assert html =~ "Rendered mix me-mix.wav"
      mixed = Path.join([root, "sounds", "mix me-mix.wav"])
      assert File.regular?(mixed)

      # Tracks SUM: both clips start at 0 on their own tracks, so the render is
      # as long as the longer one, not the two end to end.
      {:ok, clip} = SoundStudio.import_source(mixed)
      assert_in_delta SoundStudio.duration_ms(clip), 1_320.0, 20.0

      # And the result is opened, so you can hear what you just made.
      assert render(view) =~ ~s(phx-value-id="sound:mix me-mix.wav")
    end

    test "rendering offers to assign the result to a notification", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "doorbell")
      add_clip(view, "sound:alarm.wav", 0)

      html = view |> element("button[phx-click='render_mix']") |> render_click()

      # The render is the moment a mix becomes a sound, which is when "what is
      # it FOR?" is worth asking. Asking later means never asking.
      assert html =~ "Play it for"
      assert html =~ ~s(<option value="alarm">Alarms</option>)

      html =
        view
        |> form("form[phx-submit='assign_render']", %{
          "key" => "alarm",
          "name" => "doorbell-mix.wav"
        })
        |> render_submit()

      assert html =~ "Alarms now plays doorbell-mix.wav."
      # The render already lives in the library the app plays from, which is
      # what puts it in Settings → Notify's list without any further step.
      assert File.regular?(Path.join([root, "sounds", "doorbell-mix.wav"]))
      assert "doorbell-mix.wav" in Sound.list()
      assert Sound.sound_map()["alarm"] == "doorbell-mix.wav"

      # Routed BY NAME, so the built-in alarm is untouched and Settings → Notify
      # can still change its mind.
      assert "alarm.wav" in Sound.bundled_list()
      refute File.exists?(Path.join([root, "sounds", "alarm.wav"]))
      refute html =~ "Play it for"
    end

    # The whole reason a render goes to `sounds/` rather than `sounds/studio/`:
    # Settings → Notify lists that folder, so a mix becomes a choosable
    # notification sound with no export step and no second gesture.
    test "a rendered mix shows up on the Settings page by itself", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "chime idea")
      add_clip(view, "sound:boot.wav", 0)
      view |> element("button[phx-click='render_mix']") |> render_click()

      {:ok, _settings, html} = live(conn, ~p"/notify-settings")

      assert html =~ "chime idea-mix"
      assert "chime idea-mix.wav" in Sound.list()
    end

    test "assigning is offered, not imposed — Not now keeps the render", %{
      conn: conn,
      root: root
    } do
      {view, _html} = open_studio(conn)
      new_audio(view, "sketch")
      add_clip(view, "sound:boot.wav", 0)
      view |> element("button[phx-click='render_mix']") |> render_click()

      html = view |> element("button[phx-click='close_assign']", "Not now") |> render_click()

      refute html =~ "Play it for"
      assert Sound.sound_map() == %{}
      # The render is a finished sound whether or not it becomes a notification.
      assert File.regular?(Path.join([root, "sounds", "sketch-mix.wav"]))
    end

    test "rendering an empty mix says so instead of writing silence", %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "empty")

      html = view |> element("button[phx-click='render_mix']") |> render_click()
      assert html =~ "Add a clip before rendering"
    end

    test "a clip whose source vanished fails the whole render, loudly", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "orphan")

      File.write!(Path.join([root, "sounds", "temp.wav"]), SoundGen.render("chat"))
      add_clip(view, "sound:temp.wav")
      File.rm!(Path.join([root, "sounds", "temp.wav"]))

      html = view |> element("button[phx-click='render_mix']") |> render_click()

      # A mix missing one layer still sounds finished — you would never know.
      assert html =~ "source is missing"
      refute File.regular?(Path.join([root, "sounds", "orphan-mix.wav"]))
    end

    test "deleting a mix leaves the clips it used alone", %{conn: conn, root: root} do
      keeper = Path.join([root, "sounds", "keeper.wav"])
      File.write!(keeper, SoundGen.render("chat"))

      {view, _html} = open_studio(conn)
      new_audio(view, "doomed")
      add_clip(view, "sound:keeper.wav")

      view |> element("button[phx-click='delete_mix']") |> render_click()

      refute File.exists?(Path.join([root, "sounds", "studio", "mixes", "doomed.mix.json"]))
      # An audio is an arrangement OF clips, not a container holding them.
      assert File.regular?(keeper)
    end

    test "the transport renders a complete score the audition hook can perform",
         %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "performable")
      view |> element("button[phx-click='add_track']") |> render_click()
      add_clip(view, "sound:boot.wav", 0)

      html = render(view)

      # The Play button points at the arranger by data attribute — the hook
      # reads the score out of that element's subtree.
      [arranger_id] = Regex.run(~r/id="(studio-arranger-[^"]+)"/, html, capture: :all_but_first)
      assert html =~ ~s(phx-hook="StudioAudition")
      assert html =~ ~s(data-arranger="#{arranger_id}")
      assert html =~ "▶ Play"

      # The score: each clip declares the URL the transport fetches — the SAME
      # route the sidebar plays, so what auditions is what you placed — and
      # each region declares its audibility, so mute/solo semantics are read,
      # never recomputed in JS.
      assert html =~ ~s(data-src="/notify/sound/boot.wav")
      assert html =~ ~s(data-audible="true")

      # The playhead the transport sweeps.
      assert html =~ "data-playhead"

      # Muting flips the declared audibility — the transport obeys the same
      # attribute the dimming does.
      [track_a, _b] = track_ids(html)

      view
      |> element("button[phx-value-id='#{track_a}'][phx-click='toggle_mute']")
      |> render_click()

      assert has_element?(view, ~s([data-track][data-audible="false"]))
    end

    test "mute silences a track: the region dims and the render leaves it out",
         %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "muted mix")
      view |> element("button[phx-click='add_track']") |> render_click()
      add_clip(view, "sound:boot.wav", 0)
      add_clip(view, "sound:alarm.wav", 1)

      [_a, track_b] = view |> render() |> track_ids()

      view
      |> element("button[phx-value-id='#{track_b}'][phx-click='toggle_mute']")
      |> render_click()

      # The arrangement shows what the mix will contain. Scoped to the track
      # REGION: "opacity-40" also styles disabled buttons all over the app, so
      # a page-wide match would pass no matter what the arranger did.
      assert has_element?(view, "[data-track].opacity-40")
      assert has_element?(view, "button[phx-click='toggle_mute'][aria-pressed='true']")

      view |> element("button[phx-click='render_mix']") |> render_click()
      mixed = Path.join([root, "sounds", "muted mix-mix.wav"])
      assert File.regular?(mixed)

      # alarm (1.32 s) was on the muted track; boot alone is ~0.7 s. A mix as
      # long as alarm would mean M rendered anyway — the lie this exists to
      # prevent.
      {:ok, boot} =
        SoundStudio.import_source(BusterClaw.Notifications.Sound.resolve_path("boot.wav"))

      {:ok, clip} = SoundStudio.import_source(mixed)
      assert_in_delta SoundStudio.duration_ms(clip), SoundStudio.duration_ms(boot), 20.0
    end

    test "solo isolates: every unsoloed region dims and stays out of the mix",
         %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)
      new_audio(view, "solo mix")
      view |> element("button[phx-click='add_track']") |> render_click()
      add_clip(view, "sound:boot.wav", 0)
      add_clip(view, "sound:alarm.wav", 1)

      [track_a, _b] = view |> render() |> track_ids()

      view
      |> element("button[phx-value-id='#{track_a}'][phx-click='toggle_solo']")
      |> render_click()

      # B never touched its own buttons and dims anyway — silence caused by
      # someone else's S must be as visible as your own M.
      assert has_element?(view, "[data-track].opacity-40")

      view |> element("button[phx-click='render_mix']") |> render_click()

      {:ok, boot} =
        SoundStudio.import_source(BusterClaw.Notifications.Sound.resolve_path("boot.wav"))

      {:ok, clip} =
        SoundStudio.import_source(Path.join([root, "sounds", "solo mix-mix.wav"]))

      assert_in_delta SoundStudio.duration_ms(clip), SoundStudio.duration_ms(boot), 20.0
    end

    test "muting everything refuses the render with its own sentence, and undo reaches it",
         %{conn: conn} do
      {view, _html} = open_studio(conn)
      new_audio(view, "all quiet")
      add_clip(view, "sound:boot.wav")

      [track_a] = view |> render() |> track_ids()

      view
      |> element("button[phx-value-id='#{track_a}'][phx-click='toggle_mute']")
      |> render_click()

      html = view |> element("button[phx-click='render_mix']") |> render_click()

      # Clips exist; mute silenced them. "Add a clip" would be a wrong
      # diagnosis pointing at a fix the user does not need.
      assert html =~ "unmute or solo something"

      # Mute rides the same save path as every other edit, so ⌘Z takes it back.
      render_hook(view, "studio_undo", %{})
      refute has_element?(view, "[data-track].opacity-40")
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
      refute html =~ ~s(<option value="mix:outer")
    end
  end

  describe "arranger keyboard actions" do
    defp start_audio(conn, name) do
      {view, _html} = open_studio(conn)
      view |> element("#studio-new-mix") |> render_submit(%{"name" => name})
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
      {:ok, audio} = StudioMix.load(name)
      assert length(StudioMix.clips(audio)) == 1

      assert File.regular?(Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"]))
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

      view |> element("button[phx-value-tab='voice']") |> render_click()
      view |> element("button[phx-value-tab='mix']") |> render_click()
      html = select(view, "mix:durable keys")

      # An undo stack that evaporates on a glance at Chat reads as the feature
      # being broken — which is why it lives in StatusLive, not the component.
      assert html =~ "copied: boot.wav"
      refute html =~ ~r/phx-click="studio_undo" disabled/
    end

    test "switching mixes drops the history rather than undoing into the wrong one",
         %{conn: conn} do
      {view, _name} = start_audio(conn, "first")
      add(view, "sound:boot.wav")

      view |> element("#studio-new-mix") |> render_submit(%{"name" => "second"})
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

  describe "deleting from the sidebar (right-click menu)" do
    # The hook's two-step confirm is client-side; the server contract it lands
    # on is this event, routed to the component by pushEventTo(el).
    defp delete_via_menu(view, id) do
      view |> element("#studio-ctx") |> render_hook("delete_source", %{"id" => id})
    end

    test "deletes an import and drops its row", %{conn: conn, root: root} do
      dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(dir)
      path = Path.join(dir, "scrap.wav")
      File.write!(path, SoundGen.render("chat"))

      {view, html} = open_studio(conn)
      assert html =~ ~s(phx-value-id="import:scrap.wav")

      html = delete_via_menu(view, "import:scrap.wav")

      refute File.exists?(path)
      refute html =~ ~s(phx-value-id="import:scrap.wav")
      assert html =~ "Deleted scrap."
    end

    test "deleting the selected source clears the selection", %{conn: conn, root: root} do
      dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "scrap.wav"), SoundGen.render("chat"))

      {view, _html} = open_studio(conn)
      select(view, "import:scrap.wav")
      delete_via_menu(view, "import:scrap.wav")

      # Selection lives in StatusLive; the clear arrives as a message, so the
      # settled truth is the next full render.
      assert render(view) =~ "Pick something on the left"
    end

    test "a bundled chime fails closed and keeps resolving", %{conn: conn} do
      {view, _html} = open_studio(conn)

      html = delete_via_menu(view, "sound:confirm.wav")

      assert html =~ "Nothing of yours to delete there."
      assert Sound.resolve_path("confirm.wav")
    end

    test "deleting a sound override is reversion: the built-in comes back", %{
      conn: conn,
      root: root
    } do
      sounds = Path.join(root, "sounds")
      File.mkdir_p!(sounds)
      override = Path.join(sounds, "confirm.wav")
      File.write!(override, SoundGen.render("chat"))

      {view, html} = open_studio(conn)
      assert html =~ "yours"

      html = delete_via_menu(view, "sound:confirm.wav")

      refute File.exists?(override)
      assert html =~ "Removed your confirm — the built-in is back."
      # The row survives, now resolving to the shipped copy.
      assert html =~ ~s(phx-value-id="sound:confirm.wav")
    end

    test "recordings and unknown ids fail closed", %{conn: conn} do
      {view, _html} = open_studio(conn)

      assert delete_via_menu(view, "recording:123") =~ "Nothing of yours to delete there."
      assert delete_via_menu(view, "nonsense") =~ "Nothing of yours to delete there."
    end
  end

  # These tests drive the menu through `render_hook`, which is the server half
  # of a contract whose other half is JavaScript — so a rename that breaks the
  # markup/JS side is invisible to every test above. It happened on 08-02:
  # `data-ctx-new-audio` became `data-ctx-new-mix` in the markup, the hook kept
  # querying the old name, `querySelector` returned null, and the TypeError in
  # `mounted()` killed the WHOLE hook — right-click stopped working entirely,
  # with a green suite. Same lockstep idiom as the workspace registry guard.
  describe "collapsing sidebar groups" do
    defp toggle(view, key) do
      view |> element("button[phx-value-key='#{key}']") |> render_click()
    end

    test "a group folds shut and opens again, keeping its count visible", %{conn: conn} do
      {view, html} = open_studio(conn)
      assert html =~ ~s(phx-value-id="sound:boot.wav")

      html = toggle(view, "sounds")

      refute html =~ ~s(phx-value-id="sound:boot.wav")
      # The heading survives — collapsed, the count IS the summary.
      assert html =~ "Sounds"
      assert html =~ ~s(aria-expanded="false")

      html = toggle(view, "sounds")
      assert html =~ ~s(phx-value-id="sound:boot.wav")
    end

    test "folding one group leaves the others alone", %{conn: conn, root: root} do
      dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "kept.wav"), SoundGen.render("chat"))

      {view, _html} = open_studio(conn)
      html = toggle(view, "sounds")

      refute html =~ ~s(phx-value-id="sound:boot.wav")
      assert html =~ ~s(phx-value-id="import:kept.wav")
    end

    test "a folded group's rows are gone, not merely hidden", %{conn: conn, root: root} do
      dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "hidden.wav"), SoundGen.render("chat"))

      {view, _html} = open_studio(conn)
      html = toggle(view, "imports")

      # The rows carry the right-click menu's data attributes. A row hidden by
      # CSS is still a row the menu could open for something you cannot see.
      refute html =~ ~s(data-studio-source="import:hidden.wav")
    end

    # SOUND_STUDIO_ROADMAP Part V landmine 2: the sub-tab's `:if` REMOVES the
    # component, so anything it owned is lost. A sidebar that re-expands every
    # time you look at another tab is not collapsible, it is briefly tidy.
    test "a fold survives leaving the tab", %{conn: conn} do
      {view, _html} = open_studio(conn)
      toggle(view, "sounds")

      render_click(view, "select_studio_tab", %{"tab" => "voice"})
      html = render_click(view, "select_studio_tab", %{"tab" => "mix"})

      refute html =~ ~s(phx-value-id="sound:boot.wav")
      assert html =~ ~s(aria-expanded="false")
    end

    # …and a fold that survives a tab switch but not a restart is a preference
    # the app keeps forgetting. A fresh mount is this test's restart.
    test "a fold survives a restart", %{conn: conn} do
      {view, _html} = open_studio(conn)
      toggle(view, "sounds")
      assert SoundStudioComponent.collapsed_groups() == ["sounds"]

      {_fresh, html} = open_studio(conn)
      refute html =~ ~s(phx-value-id="sound:boot.wav")

      # Unfolding clears the stored row rather than leaving an empty list.
      toggle(view, "sounds")
      assert SoundStudioComponent.collapsed_groups() == []
      assert BusterClaw.Settings.get("studio_collapsed_groups") == nil
    end

    test "a stored key the app no longer ships is dropped on read" do
      BusterClaw.Settings.put(
        "studio_collapsed_groups",
        Jason.encode!(["sounds", "podcasts", "mix"])
      )

      # Same posture as Sound.sound_map/0: a group that stops existing must not
      # leave a key behind forever, and a hand-edited row cannot introduce one.
      assert SoundStudioComponent.collapsed_groups() == ["sounds", "mix"]
    end

    # The roster and the cheap key list are two statements of the same fact.
    # `group_keys/0` exists because `groups/0` reads four directories and the
    # telephony table just to answer "is this a real group?".
    test "group_keys/0 agrees with the real roster" do
      assert Enum.map(SoundStudioComponent.groups(), & &1.key) ==
               SoundStudioComponent.group_keys()
    end
  end

  describe "the menu's JS contract" do
    @hook_js "assets/js/hooks/studio_context_menu.js"
    @component_ex "lib/buster_claw_web/live/sound_studio_component.ex"

    test "every data-ctx attribute the hook queries exists in the markup", %{conn: conn} do
      {_view, html} = open_studio(conn)

      selectors =
        @hook_js
        |> File.read!()
        |> then(&Regex.scan(~r/\[(data-ctx-[a-z-]+)\]/, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.uniq()

      assert selectors != [], "no data-ctx selectors found — did the hook move?"

      for selector <- selectors do
        assert html =~ selector,
               "the hook queries [#{selector}], and the menu markup has no such attribute"
      end
    end

    test "every event the hook pushes has a handler on the component" do
      source = File.read!(@component_ex)

      events =
        @hook_js
        |> File.read!()
        |> then(&Regex.scan(~r/this\.push\("([a-z_]+)"\)/, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.uniq()

      assert events != [], "no pushed events found — did the hook move?"

      for event <- events do
        assert source =~ ~s(handle_event("#{event}"),
               "the hook pushes #{event}, and the component has no handle_event for it"
      end
    end
  end

  describe "the sidebar menu's other two verbs" do
    defp menu_hook(view, event, params) when is_map(params) do
      view |> element("#studio-ctx") |> render_hook(event, params)
    end

    defp menu_hook(view, event, id), do: menu_hook(view, event, %{"id" => id})

    defp import!(root, name, key \\ "chat") do
      dir = Path.join([root, "sounds", "studio"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name), SoundGen.render(key))
    end

    test "the menu offers Info and New audio only for real files", %{conn: conn, root: root} do
      import!(root, "clip.wav")
      {:ok, name} = StudioMix.create("arrangement")

      {_view, html} = open_studio(conn)

      # A file on disk has facts and can become a clip; an arrangement is a list
      # of references to files, so it is neither.
      assert html =~
               ~s(data-studio-source="import:clip.wav" data-source-label="clip") <>
                 ~s( data-deletable="true" data-sourceable="true")

      refute html =~ ~s(data-studio-source="mix:#{name}") <> ~s([^>]*data-sourceable)
    end

    test "Info reports the path, size, and header facts without decoding", %{
      conn: conn,
      root: root
    } do
      import!(root, "long.wav")
      {view, _html} = open_studio(conn)

      html = menu_hook(view, "source_info", "import:long.wav")

      assert html =~ Path.join([root, "sounds", "studio", "long.wav"])
      assert html =~ "22050 Hz · 1 ch"
      assert html =~ "On disk"

      html = view |> element("button[phx-click='close_info']", "×") |> render_click()
      refute html =~ "On disk"
    end

    test "Info on a file whose bytes are gone says so rather than lying", %{
      conn: conn,
      root: root
    } do
      import!(root, "ghost.wav")
      {view, _html} = open_studio(conn)
      File.rm!(Path.join([root, "sounds", "studio", "ghost.wav"]))

      html = menu_hook(view, "source_info", "import:ghost.wav")
      assert html =~ "This file is gone from disk."
    end

    test "New mix creates an arrangement with the source already on it", %{
      conn: conn,
      root: root
    } do
      import!(root, "bells.wav")
      {view, _html} = open_studio(conn)

      html = menu_hook(view, "new_mix_from_source", "import:bells.wav")

      assert html =~ "New mix “bells” from bells."
      assert {:ok, audio} = StudioMix.load("bells")

      # On the first track, at the top of the ruler, with a real length — an
      # empty arrangement you then have to fill is the version nobody uses.
      assert [%{clips: [clip]} | _rest] = audio.tracks
      assert clip.source == "import:bells.wav"
      assert clip.start_ms == 0.0
      assert clip.duration_ms > 0

      # And it opens, because making it and then hiding it is not the gesture.
      assert render(view) =~ ~s(phx-value-id="mix:bells")
    end

    test "renaming an import carries every mix clip with it", %{conn: conn, root: root} do
      import!(root, "rough.wav")
      {view, _html} = open_studio(conn)

      # A mix that uses it. The clip stores "import:rough.wav" — a reference,
      # which is what a rename could orphan.
      menu_hook(view, "new_mix_from_source", "import:rough.wav")

      html = menu_hook(view, "rename_source", %{"id" => "import:rough.wav", "name" => "polished"})

      assert html =~ "Renamed to polished."
      assert html =~ "One mix follows it."
      assert File.regular?(Path.join([root, "sounds", "studio", "polished.wav"]))
      refute File.regular?(Path.join([root, "sounds", "studio", "rough.wav"]))

      # The clip points at the new name, so the mix still renders.
      assert {:ok, mix} = StudioMix.load("rough")
      assert [{_track, %{source: "import:polished.wav"}}] = StudioMix.clips(mix)
    end

    test "the extension is not the user's to change", %{conn: conn, root: root} do
      import!(root, "keep.wav")
      {view, _html} = open_studio(conn)

      menu_hook(view, "rename_source", %{"id" => "import:keep.wav", "name" => "sneaky.txt"})

      # Renaming must not be able to turn a .wav into something else: the typed
      # extension is dropped and the real one kept.
      assert File.regular?(Path.join([root, "sounds", "studio", "sneaky.wav"]))
      refute File.exists?(Path.join([root, "sounds", "studio", "sneaky.txt"]))
    end

    test "a taken name is refused rather than silently suffixed", %{conn: conn, root: root} do
      import!(root, "one.wav")
      import!(root, "two.wav")
      {view, _html} = open_studio(conn)

      html = menu_hook(view, "rename_source", %{"id" => "import:one.wav", "name" => "two"})

      assert html =~ "Something is already called that."
      assert File.regular?(Path.join([root, "sounds", "studio", "one.wav"]))
    end

    test "an empty name is refused", %{conn: conn, root: root} do
      import!(root, "named.wav")
      {view, _html} = open_studio(conn)

      html = menu_hook(view, "rename_source", %{"id" => "import:named.wav", "name" => "   "})

      assert html =~ "That name has nothing in it."
      assert File.regular?(Path.join([root, "sounds", "studio", "named.wav"]))
    end

    test "renaming a sound repoints its routing, and un-overrides the built-in", %{
      conn: conn,
      root: root
    } do
      File.write!(Path.join([root, "sounds", "confirm.wav"]), SoundGen.render("chat"))
      Sound.assign("chat", "confirm.wav")

      {view, _html} = open_studio(conn)

      html =
        menu_hook(view, "rename_source", %{"id" => "sound:confirm.wav", "name" => "doorbell"})

      assert html =~ "Renamed to doorbell."
      # The route follows the file — a rename must not silently unhook a chime.
      assert Sound.sound_map()["chat"] == "doorbell.wav"
      # And confirm is no longer overridden, so the built-in answers again.
      refute File.exists?(Path.join([root, "sounds", "confirm.wav"]))
      assert Sound.resolve_path("confirm.wav")
    end

    test "a built-in chime and a recording refuse to be renamed", %{conn: conn} do
      {view, _html} = open_studio(conn)

      assert menu_hook(view, "rename_source", %{"id" => "sound:alarm.wav", "name" => "nope"}) =~
               "Nothing of yours to rename there."

      assert menu_hook(view, "rename_source", %{"id" => "recording:1", "name" => "nope"}) =~
               "Nothing of yours to rename there."
    end

    test "renaming a mix moves the name inside the file too", %{conn: conn} do
      {:ok, _name} = StudioMix.create("draft")
      {view, _html} = open_studio(conn)

      html = menu_hook(view, "rename_source", %{"id" => "mix:draft", "name" => "final cut"})

      assert html =~ "Renamed to final cut."
      assert StudioMix.list() == ["final cut"]
      assert {:ok, mix} = StudioMix.load("final cut")
      # A file whose contents disagree with its name surfaces months later.
      assert mix.name == "final cut"
    end

    test "New mix refuses an id with no file behind it", %{conn: conn} do
      {view, _html} = open_studio(conn)

      html = menu_hook(view, "new_mix_from_source", "nonsense")
      # "New mix" alone is the toolbar's own button; the note is the tell.
      refute html =~ "New mix “"
      assert StudioMix.list() == []
    end
  end
end
