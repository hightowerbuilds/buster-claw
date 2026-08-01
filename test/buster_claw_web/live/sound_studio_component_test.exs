defmodule BusterClawWeb.SoundStudioComponentTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClawWeb.SoundStudioComponent

  setup do
    root = Path.join(System.tmp_dir!(), "bc_studio_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))
    File.mkdir_p!(Path.join(root, "music"))

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
      BusterClaw.Notifications.Sound.ensure()

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

  describe "importing" do
    test "offers a way in, and names where files land", %{conn: conn} do
      {_view, html} = open_studio(conn)

      assert html =~ "Import audio"
      assert html =~ "studio/"
      assert html =~ "Imports"
    end

    test "an imported file lands in studio/ and appears in the sidebar", %{
      conn: conn,
      root: root
    } do
      {view, _html} = open_studio(conn)

      file =
        file_input(view, "#studio-import", :import, [
          %{name: "clip.wav", content: SoundGen.render("chat"), type: "audio/wav"}
        ])

      render_upload(file, "clip.wav")
      html = view |> element("#studio-import") |> render_submit()

      assert File.regular?(Path.join([root, "studio", "clip.wav"]))
      assert html =~ "Imported 1 file"
      assert html =~ ~s(phx-value-id="import:clip.wav")
    end

    test "a file that cannot be decoded is refused with a reason", %{conn: conn, root: root} do
      {view, _html} = open_studio(conn)

      file =
        file_input(view, "#studio-import", :import, [
          %{name: "prose.wav", content: "I am prose wearing a .wav extension", type: "audio/wav"}
        ])

      render_upload(file, "prose.wav")
      html = view |> element("#studio-import") |> render_submit()

      # The gate is a decode, not an extension — and it says so rather than
      # failing silently.
      assert html =~ "couldn&#39;t be decoded" or html =~ "couldn't be decoded"
      refute File.regular?(Path.join([root, "studio", "prose.wav"]))
    end

    test "an imported file is selectable and served from its own route", %{conn: conn} do
      {view, _html} = open_studio(conn)

      file =
        file_input(view, "#studio-import", :import, [
          %{name: "cut.wav", content: SoundGen.render("alarm"), type: "audio/wav"}
        ])

      render_upload(file, "cut.wav")
      view |> element("#studio-import") |> render_submit()

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
      trimmed = Path.join([root, "studio", "alarm-trim.wav"])
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

      assert File.regular?(Path.join([root, "studio", "alarm-trim.wav"]))
      assert File.regular?(Path.join([root, "studio", "alarm-trim-2.wav"]))
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

  describe "the music library manager" do
    test "keeps a home inside the Studio", %{conn: conn} do
      {view, _html} = open_studio(conn)
      html = select(view, SoundStudioComponent.music_library_id())

      # Upload/queue/delete did not disappear with the tab rename.
      assert html =~ "Add music"
    end
  end
end
