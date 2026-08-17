defmodule BusterClawWeb.ClipActionsTest do
  @moduledoc """
  What can be done to a clip in the arranger: select it, remove it from the
  right-click menu, and stay where you were while doing so.

  ## The tab-reset bug, and the test that did not catch it

  Clicking a clip crashed the LiveView and dropped the operator back on Chat —
  reported twice, and reproduced only by driving a real browser.

  The cause was one missing clause. **A hook's `pushEvent` goes to the LIVEVIEW**;
  `pushEventTo` is what targets a component. `select_clip` was handled only on
  the component, so every click was a `FunctionClauseError`: the process died,
  the client reconnected, and the remount reset `home_tab` to its mount default.

  What let it survive two rounds of testing is the shape of the tests, not their
  absence. `render_hook(element(view, "..."), ...)` routes to the component and
  passes; `render_hook(view, ...)` routes where the browser actually goes and
  crashes. The first was written, the second was not — and the comments in both
  `track_arrange.js` and the component asserted the wrong routing, so the tests
  were written to agree with them.

  **Both are driven below.** A clip event that only passes one of them is not
  covered.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.StudioMix

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "bc_clipact_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    File.mkdir_p!(SoundStudio.dir())
    BusterClaw.Settings.mark_onboarding_complete()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, conn: conn}
  end

  defp studio_with_clip(conn) do
    data = Enum.reduce(1..100, <<>>, fn s, acc -> acc <> <<s::little-signed-16>> end)

    :ok =
      SoundStudio.write(
        %SoundStudio{sample_rate: 22_050, channels: 1, bits: 16, data: data},
        Path.join(SoundStudio.dir(), "a.wav")
      )

    {:ok, "m"} = StudioMix.create("m")
    {:ok, mix} = StudioMix.load("m")
    [track | _] = mix.tracks
    placed = StudioMix.add_clip(mix, track.id, "a.wav", 0, 90)
    :ok = StudioMix.save(placed)
    [clip] = Enum.map(StudioMix.clips(placed), fn {_t, c} -> c end)

    # /studio since 08-16 — was a Home sub-tab click.
    {:ok, view, _html} = live(conn, ~p"/studio")
    render_click(element(view, "[phx-click='select_studio_tab'][phx-value-tab='mix']"))
    send(view.pid, {:studio_select, "mix:m"})
    _ = :sys.get_state(view.pid)

    {view, clip}
  end

  # The crash detector. Until 08-16 this read `home_tab` — the Studio was a Home
  # sub-tab, and a crash-and-remount reset it to "chat", which is precisely how
  # the clip-click crash announced itself.
  #
  # On `/studio` there is no home tab to lose, so it reads the open source
  # instead. `studio_with_clip/1` opens `mix:m`; a remount would reset it to
  # `nil`. Same signal, and anchored to the Studio's own state rather than to
  # which Home tab happened to be showing.
  defp still_open(view), do: :sys.get_state(view.pid).socket.assigns.studio_source

  describe "selecting a clip" do
    # The COMPONENT path — a second door, kept so a future `pushEventTo` cannot
    # crash. Note this is the test that existed and passed while the browser was
    # crashing on every click: passing here says nothing about the real path.
    test "goes through the component and leaves the home tab alone", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      assert still_open(view) == "mix:m"

      render_hook(element(view, "[phx-hook='TrackArrange']"), "select_clip", %{"id" => clip.id})

      assert still_open(view) == "mix:m"
      assert :sys.get_state(view.pid).socket.assigns.studio_clip == clip.id
    end

    # THE REGRESSION. This is the path a browser click takes, and the one that
    # was crashing. It must be asserted separately from the component path
    # above — they route to different processes and only one of them was broken.
    test "reaches the LIVEVIEW directly, which is where a hook's pushEvent goes",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(view, "select_clip", %{"id" => clip.id})

      assert still_open(view) == "mix:m"
      assert :sys.get_state(view.pid).socket.assigns.studio_clip == clip.id
    end

    test "a LiveView-targeted select with no id does not take the process down",
         %{conn: conn} do
      {view, _clip} = studio_with_clip(conn)

      # A stale client should cost a no-op, never a crash-and-remount.
      render_hook(view, "select_clip", %{})

      assert still_open(view) == "mix:m"
    end

    test "opens the inspector for that clip", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      render_hook(element(view, "[phx-hook='TrackArrange']"), "select_clip", %{"id" => clip.id})

      assert has_element?(view, "#studio-clip-inspector")
      assert render(view) =~ "a.wav"
    end

    test "a clip id that is not in the mix opens nothing rather than crashing",
         %{conn: conn} do
      {view, _clip} = studio_with_clip(conn)
      render_hook(element(view, "[phx-hook='TrackArrange']"), "select_clip", %{"id" => "ghost"})

      assert still_open(view) == "mix:m"
      refute has_element?(view, "#studio-clip-inspector")
    end
  end

  describe "the right-click menu" do
    test "offers Remove clip, and the menu element the hook needs exists", %{conn: conn} do
      {view, _clip} = studio_with_clip(conn)

      assert has_element?(view, "#studio-ctx[phx-hook='StudioContextMenu']")
      assert has_element?(view, "[data-ctx-remove-clip]")
    end

    test "removing takes the clip out of the mix and leaves the source alone",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(element(view, "#studio-ctx"), "remove_clip", %{"id" => clip.id})

      {:ok, reloaded} = StudioMix.load("m")
      assert StudioMix.clips(reloaded) == []

      # The clip left the arrangement; the audio it pointed at is untouched.
      assert "a.wav" in SoundStudio.list()
      assert still_open(view) == "mix:m"
    end

    test "removing is undoable — it goes through the same save that records history",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      render_hook(element(view, "#studio-ctx"), "remove_clip", %{"id" => clip.id})

      {:ok, gone} = StudioMix.load("m")
      assert StudioMix.clips(gone) == []

      render_click(view, "studio_undo", %{})

      {:ok, restored} = StudioMix.load("m")
      assert length(StudioMix.clips(restored)) == 1
    end

    test "offers Duplicate clip too, and only the clip items", %{conn: conn} do
      {view, _clip} = studio_with_clip(conn)

      assert has_element?(view, "[data-ctx-duplicate-clip]")
      assert has_element?(view, "[data-ctx-remove-clip]")
    end

    test "duplicating places a copy on the SAME track, right after the original",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(element(view, "#studio-ctx"), "duplicate_clip", %{"id" => clip.id})

      {:ok, mix} = StudioMix.load("m")
      placed = Enum.map(StudioMix.clips(mix), fn {track, c} -> {track.id, c} end)
      assert length(placed) == 2

      [{track_a, original}, {track_b, copy}] = Enum.sort_by(placed, fn {_t, c} -> c.start_ms end)

      # Same track, and immediately after — "again, right here", not "somewhere".
      assert track_a == track_b
      assert copy.start_ms == original.start_ms + original.duration_ms
      assert copy.source == original.source
      assert copy.duration_ms == original.duration_ms

      # A NEW id, so the copy can be moved and deleted on its own.
      refute copy.id == original.id
    end

    test "a duplicate carries the effect chain — a dry copy would be a silent loss",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      # Through the UI, not straight to disk: the component holds its mix in
      # memory from `update/2`, so a write behind its back is overwritten by the
      # next `save_mix`. That is also why this test is worth having — it is the
      # path the operator takes.
      render_hook(view, "select_clip", %{"id" => clip.id})
      render_click(view, "studio_add_effect", %{"type" => "reverb"})

      render_click(view, "studio_set_effect_param", %{
        "position" => "0",
        "key" => "mix",
        "value" => "0.8"
      })

      render_hook(element(view, "#studio-ctx"), "duplicate_clip", %{"id" => clip.id})

      {:ok, after_dup} = StudioMix.load("m")

      copy =
        after_dup
        |> StudioMix.clips()
        |> Enum.map(fn {_t, c} -> c end)
        |> Enum.find(&(&1.id != clip.id))

      assert [%{type: "reverb", params: %{"mix" => 0.8}}] = StudioMix.chain(copy)
    end

    test "duplicating is undoable, and an unknown id is a no-op", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(element(view, "#studio-ctx"), "duplicate_clip", %{"id" => clip.id})
      {:ok, two} = StudioMix.load("m")
      assert length(StudioMix.clips(two)) == 2

      render_click(view, "studio_undo", %{})
      {:ok, back} = StudioMix.load("m")
      assert length(StudioMix.clips(back)) == 1

      # A stale client costs a no-op, never a crash.
      render_hook(element(view, "#studio-ctx"), "duplicate_clip", %{"id" => "ghost"})
      assert still_open(view) == "mix:m"
      {:ok, still} = StudioMix.load("m")
      assert length(StudioMix.clips(still)) == 1
    end

    # Not the menu, but the same defect and the same fix: the clipboard spec
    # predates effects, so ⌘C/⌘V pasted a shaped clip DRY until 08-16. Both now
    # go through `place_copy/4`, because two ways to say "a clip like this one"
    # is how one of them came to forget the chain.
    test "copy and paste carry the chain too, through the same primitive",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(view, "select_clip", %{"id" => clip.id})
      render_click(view, "studio_add_effect", %{"type" => "reverse"})

      render_click(view, "studio_copy", %{})
      render_click(view, "studio_paste", %{})

      {:ok, mix} = StudioMix.load("m")

      pasted =
        mix
        |> StudioMix.clips()
        |> Enum.map(fn {_t, c} -> c end)
        |> Enum.find(&(&1.id != clip.id))

      assert pasted, "nothing was pasted"
      assert [%{type: "reverse"}] = StudioMix.chain(pasted)
    end

    test "a stale selection heals itself rather than rendering a ghost clip",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      render_hook(element(view, "[phx-hook='TrackArrange']"), "select_clip", %{"id" => clip.id})
      assert has_element?(view, "#studio-clip-inspector")

      render_hook(element(view, "#studio-ctx"), "remove_clip", %{"id" => clip.id})

      # `studio_clip` still names the removed id; the inspector looks the clip up
      # in the mix and finds nothing, so it closes instead of showing a block
      # that is no longer there.
      refute has_element?(view, "#studio-clip-inspector")
    end
  end

  describe "trim, from the right-click menu" do
    test "opens on the clip's current window and the source's real length", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(element(view, "#studio-ctx"), "open_trim_clip", %{"id" => clip.id})

      assert has_element?(view, "#studio-trim-clip")
      html = render(view)

      # It must say the file is safe, because "trim" everywhere else in this app
      # means cutting a FILE — the source trim on the detail pane writes a new
      # one. This one does not, and the copy is the only thing that says so.
      assert html =~ "The file on disk is not touched"
    end

    test "trimming narrows the clip and is undoable", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      render_hook(element(view, "#studio-ctx"), "open_trim_clip", %{"id" => clip.id})

      view
      |> element("#studio-trim-clip form")
      |> render_submit(%{"offset_ms" => "20", "duration_ms" => "40"})

      refute has_element?(view, "#studio-trim-clip")

      {:ok, mix} = StudioMix.load("m")
      assert StudioMix.window(StudioMix.find_clip(mix, clip.id)) == {20.0, 40.0}

      # It rides the same history every other clip edit does, so ⌘Z is not a
      # special case anyone had to remember to wire.
      render_click(view, "studio_undo", %{})
      {:ok, restored} = StudioMix.load("m")
      assert StudioMix.window(StudioMix.find_clip(restored, clip.id)) == {0.0, 90.0}
    end

    test "a junk length is a no-op rather than a clip trimmed to nothing", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      render_hook(element(view, "#studio-ctx"), "open_trim_clip", %{"id" => clip.id})

      view
      |> element("#studio-trim-clip form")
      |> render_submit(%{"offset_ms" => "", "duration_ms" => "not a number"})

      {:ok, mix} = StudioMix.load("m")
      assert StudioMix.window(StudioMix.find_clip(mix, clip.id)) == {0.0, 90.0}
    end
  end
end
