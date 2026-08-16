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

    {:ok, view, _html} = live(conn, ~p"/")
    render_click(element(view, "[phx-click='select_home_tab'][phx-value-tab='studio']"))
    render_click(element(view, "[phx-click='select_studio_tab'][phx-value-tab='mix']"))
    send(view.pid, {:studio_select, "mix:m"})
    _ = :sys.get_state(view.pid)

    {view, clip}
  end

  defp home_tab(view), do: :sys.get_state(view.pid).socket.assigns.home_tab

  describe "selecting a clip" do
    # The COMPONENT path — a second door, kept so a future `pushEventTo` cannot
    # crash. Note this is the test that existed and passed while the browser was
    # crashing on every click: passing here says nothing about the real path.
    test "goes through the component and leaves the home tab alone", %{conn: conn} do
      {view, clip} = studio_with_clip(conn)
      assert home_tab(view) == "studio"

      render_hook(element(view, "[phx-hook='TrackArrange']"), "select_clip", %{"id" => clip.id})

      assert home_tab(view) == "studio"
      assert :sys.get_state(view.pid).socket.assigns.studio_clip == clip.id
    end

    # THE REGRESSION. This is the path a browser click takes, and the one that
    # was crashing. It must be asserted separately from the component path
    # above — they route to different processes and only one of them was broken.
    test "reaches the LIVEVIEW directly, which is where a hook's pushEvent goes",
         %{conn: conn} do
      {view, clip} = studio_with_clip(conn)

      render_hook(view, "select_clip", %{"id" => clip.id})

      assert home_tab(view) == "studio"
      assert :sys.get_state(view.pid).socket.assigns.studio_clip == clip.id
    end

    test "a LiveView-targeted select with no id does not take the process down",
         %{conn: conn} do
      {view, _clip} = studio_with_clip(conn)

      # A stale client should cost a no-op, never a crash-and-remount.
      render_hook(view, "select_clip", %{})

      assert home_tab(view) == "studio"
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

      assert home_tab(view) == "studio"
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
      assert home_tab(view) == "studio"
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
      assert home_tab(view) == "studio"
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
end
