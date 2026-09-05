defmodule BusterClawWeb.VoiceLiveEngineTest do
  @moduledoc """
  The engine panel, which reports on a binary that is not installed here and
  cannot be. Application env steers resolution, which is global, so this cannot
  be async and cannot live in `voice_live_test.exs` beside the async cases.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Voice.Chimes
  alias BusterClaw.Voice.Config
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Greeting

  setup do
    previous = Application.get_env(:buster_claw, :voxcpm_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :voxcpm_path, previous),
        else: Application.delete_env(:buster_claw, :voxcpm_path)

      Engine.refresh()
    end)

    :ok
  end

  test "with no engine, it says so and gives the line to fix it", %{conn: conn} do
    absent()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ "Not installed"
    assert html =~ "pip install voxcpm"
    # The honest framing: absence is the normal state, not a broken one.
    assert html =~ "your Mac&#39;s own voices" or html =~ "your Mac's own voices"
    # `Check again` is the only control here, and it is offered whether or not
    # anything is installed — re-reading the disk is exactly what you do after
    # following the install line above.
    assert html =~ "engine-recheck"
  end

  test "an install that cannot be run gets a different sentence from a missing one", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "voxcpm_noexec_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o644)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ "cannot be run"
    refute html =~ "Not installed."
  end

  test "an installed engine reports its path and device, and nothing to click", %{conn: conn} do
    path = stub()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ path
    # The install instructions are for people who need them.
    refute html =~ "pip install voxcpm"

    # The "Run it" liveness button was deleted 09-05 (operator: you clicked it
    # and read "It answered", which is not an experience). Asserted as an absence
    # in the state where it used to appear, because the argument against it is
    # not that it was broken — it worked — but that a check with no payoff is
    # exactly the kind of control that gets added back by someone tidying up.
    # The real proof of life is typing a line under Make and hearing it.
    refute html =~ "engine-verify"
  end

  test "Check again re-reads the disk, which is the whole point of it", %{conn: conn} do
    absent()
    {:ok, view, html} = live(conn, ~p"/voice")
    assert html =~ "Not installed"

    # Install it underneath, exactly as an operator would while the page is open.
    stub()

    html = view |> element("button[phx-click=engine-recheck]") |> render_click()

    refute html =~ "Not installed"
    refute html =~ "pip install voxcpm"
  end

  describe "the spoken chime set" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_vlive_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "sounds"))
      previous = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)
      Application.put_env(:buster_claw, :voxcpm_device, "cpu")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:buster_claw, :workspace_root, previous),
          else: Application.delete_env(:buster_claw, :workspace_root)

        Application.delete_env(:buster_claw, :voxcpm_device)
        File.rm_rf(root)
      end)

      {:ok, root: root}
    end

    test "every line is shown and editable", %{conn: conn} do
      absent()
      {:ok, _view, html} = live(conn, ~p"/voice")

      for key <- Chimes.keys() do
        assert html =~ ~s(name="lines[#{key}]")
      end

      assert html =~ Chimes.defaults()["timer"]
    end

    test "editing a line persists it, and reset puts it back", %{conn: conn} do
      absent()
      {:ok, view, _html} = live(conn, ~p"/voice")

      html =
        view
        |> form("form[phx-submit=chime-lines-save]", %{"lines" => %{"timer" => "Time, boss."}})
        |> render_submit()

      assert html =~ "Time, boss."
      assert Chimes.line("timer") == "Time, boss."

      html = view |> element("button[phx-click=chime-lines-reset]") |> render_click()
      assert html =~ Chimes.defaults()["timer"]
      assert Chimes.line("timer") == Chimes.defaults()["timer"]
    end

    test "with no engine, speaking them is offered but disabled", %{conn: conn} do
      absent()
      {:ok, _view, html} = live(conn, ~p"/voice")

      assert html =~ "chime-render-all"
      assert html =~ "Editing works without an engine"
      # The button is present but cannot be pressed — an affordance that explains
      # itself beats one that vanishes.
      assert html =~ ~r/phx-click="chime-render-all"[^>]*disabled/s
    end

    test "with an engine, the set renders and installs itself", %{conn: conn, root: root} do
      stub_writing_wav(root)
      {:ok, view, _html} = live(conn, ~p"/voice")

      view |> element("button[phx-click=chime-render-all]") |> render_click()

      # Renders arrive on the renderer's topic and are installed as they land.
      assert eventually(fn -> Chimes.installed?("timer") end),
             "expected the timer chime to be installed"

      assert File.regular?(Path.join([root, "sounds", "voice-timer.wav"]))
      assert BusterClaw.Notifications.Sound.resolved("timer") == "voice-timer.wav"

      # And the page says so.
      assert eventually(fn -> render(view) =~ "spoken" end)
    end
  end

  describe "engine settings" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_vcfg_live_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "sounds"))
      previous = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)
      Application.put_env(:buster_claw, :voxcpm_device, "cpu")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:buster_claw, :workspace_root, previous),
          else: Application.delete_env(:buster_claw, :workspace_root)

        Application.delete_env(:buster_claw, :voxcpm_device)
        File.rm_rf(root)
      end)

      {:ok, root: root}
    end

    test "every knob is on the page, and the count says what a change costs", %{conn: conn} do
      absent()
      {:ok, _view, html} = live(conn, ~p"/voice")

      for field <- ~w(reference_audio control device inference_timesteps cfg_value engine_path) do
        assert html =~ ~s(name="config[#{field}]"), "no control for #{field}"
      end

      assert html =~ "0 of 16"
    end

    test "saving a reference clip is refused when the file is not there, and says so", %{
      conn: conn,
      root: root
    } do
      absent()
      {:ok, view, _html} = live(conn, ~p"/voice")

      html =
        view
        |> form("form[phx-submit=engine-config-save]", %{
          "config" => %{"reference_audio" => Path.join(root, "nope.wav")}
        })
        |> render_submit()

      assert html =~ "Reference clip: no file there."
      refute Config.cloning?()
    end

    test "saving a real clip switches every render to cloning and re-costs the chimes",
         %{conn: conn, root: root} do
      absent()
      clip = Path.join(root, "me.wav")
      File.write!(clip, "RIFF....")
      {:ok, view, _html} = live(conn, ~p"/voice")

      html =
        view
        |> form("form[phx-submit=engine-config-save]", %{"config" => %{"reference_audio" => clip}})
        |> render_submit()

      assert Config.cloning?()
      assert html =~ "all 16 chimes need making again"
    end

    test "engine defaults clears the lot", %{conn: conn} do
      absent()
      assert :ok = Config.put(%{"control" => "gruff"})
      {:ok, view, _html} = live(conn, ~p"/voice")

      html = view |> element("button[phx-click=engine-config-reset]") |> render_click()

      assert html =~ "Back to the engine"
      assert Config.get().control == nil
    end
  end

  describe "your voice — record, then say anything" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_vrec_live_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "sounds"))
      previous = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)
      Application.put_env(:buster_claw, :voxcpm_device, "cpu")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:buster_claw, :workspace_root, previous),
          else: Application.delete_env(:buster_claw, :workspace_root)

        Application.delete_env(:buster_claw, :voxcpm_device)
        File.rm_rf(root)
      end)

      {:ok, root: root}
    end

    test "the recorder is mounted with its own event names, so it does not talk to the Studio", %{
      conn: conn
    } do
      absent()
      {:ok, _view, html} = live(conn, ~p"/voice")

      assert html =~ ~s(phx-hook="VoiceRecorder")
      assert html =~ ~s(data-event-take="reference_take")
      assert html =~ ~s(data-event-report="reference_report")
      # Every handle the hook reaches for is present.
      for role <- ~w(record meter peak clip format target-zone status) do
        assert html =~ ~s(data-role="#{role}"), "no #{role} element for the recorder"
      end

      assert html =~ "There is no training step"
    end

    test "a take pushed by the recorder becomes the reference clip and re-costs the chimes", %{
      conn: conn
    } do
      absent()
      {:ok, view, _html} = live(conn, ~p"/voice")

      html = push_take(view, tone(2_500))

      assert html =~ "This is your voice now"
      assert Config.cloning?()
      assert html =~ "in use"
      assert html =~ "0 of 16"
    end

    test "a too-short take says so and changes nothing", %{conn: conn} do
      absent()
      {:ok, view, _html} = live(conn, ~p"/voice")

      html = push_take(view, tone(500))

      assert html =~ "Too short"
      refute Config.cloning?()
    end

    test "a refused microphone is explained, with where to fix it", %{conn: conn} do
      absent()
      {:ok, view, _html} = live(conn, ~p"/voice")

      html =
        view
        |> element("#voice-recorder")
        |> render_hook("reference_report", %{
          "do" => "capability",
          "state" => "denied",
          "detail" => "NotAllowedError"
        })

      assert html =~ "Privacy"
    end

    test "typing a line makes a clip that lands in the list with a player", %{
      conn: conn,
      root: root
    } do
      stub_writing_wav(root)
      {:ok, view, _html} = live(conn, ~p"/voice")

      view
      |> form("form[phx-submit=clip_make]", %{"clip" => %{"text" => "Hello from the test."}})
      |> render_submit()

      assert eventually(fn ->
               render(view) =~ "Hello from the test." and render(view) =~ "/voice-audio/"
             end),
             "expected the clip to appear with an audio source"

      assert [%{text: "Hello from the test."}] = BusterClaw.Voice.Clips.list()
    end

    test "without a recording, the clip panel says whose voice it will be", %{conn: conn} do
      absent()
      {:ok, _view, html} = live(conn, ~p"/voice")

      assert html =~ "No recording yet"
    end

    # The host half of `VoxComponent`'s contract, and the reason it earns its own
    # test rather than riding on the `/voice` one above. A `LiveComponent` has no
    # process: a render that finishes while the HOMEPAGE is the open surface
    # reaches the panel only if `StatusLive` relays the broadcast. Delete that
    # clause and this goes red while every `/voice` test stays green — which is
    # precisely the silent staleness it exists to catch.
    test "a finished render reaches the Vox sub-tab, not just /voice", %{conn: conn, root: root} do
      stub_writing_wav(root)
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "vox"})

      view
      |> form("form[phx-submit=clip_make]", %{"clip" => %{"text" => "Spoken on the homepage."}})
      |> render_submit()

      assert eventually(fn -> render(view) =~ "Spoken on the homepage." end),
             "the Renderer broadcast never reached the component — is StatusLive still relaying?"
    end
  end

  # Aimed at the recorder ELEMENT, not at the LiveView. The surface became
  # `VoxComponent` on 09-05 when Vox got a homepage tab, and a component only
  # receives what carries its `phx-target` — which is exactly what the real hook
  # does now (`voice_recorder.js` pushes with `pushEventTo(this.el, …)`). A bare
  # `render_hook(view, …)` would test a path the browser no longer takes.
  defp push_take(view, pcm) do
    view
    |> element("#voice-recorder")
    |> render_hook("reference_take", %{"pcm" => pcm, "sample_rate" => 44_100})
  end

  defp tone(ms, rate \\ 44_100) do
    count = div(rate * ms, 1000)

    floats =
      for i <- 0..(count - 1), into: <<>> do
        <<:math.sin(2 * :math.pi() * 440 * i / rate) * 0.3::float-little-32>>
      end

    Base.encode64(floats)
  end

  describe "the phone greeting" do
    # The wire half — upload, status, drift — is covered in
    # `BusterClaw.Voice.GreetingTest` against a Req.Test plug. What is asserted
    # here is the surface: that the words are editable, that publishing is
    # confirmed rather than instant, and that an unpublished line says so.
    test "the greeting is shown, editable, and honest about not being published", %{conn: conn} do
      absent()
      {:ok, view, html} = live(conn, ~p"/voice")

      assert html =~ "What callers hear"
      # A fragment without an apostrophe: the textarea's contents are HTML
      # escaped, so the default text does not appear verbatim.
      assert html =~ "access code, enter it now"
      assert html =~ "Not published"

      html =
        view
        |> form("form[phx-submit=greeting-save]", %{"greeting" => "Hi, it's the machine."})
        |> render_submit()

      assert html =~ "Hi, it&#39;s the machine." or html =~ "Hi, it's the machine."
      assert Greeting.text() == "Hi, it's the machine."
    end

    test "publishing is behind a confirmation, because strangers hear the result",
         %{conn: conn} do
      stub()
      {:ok, _view, html} = live(conn, ~p"/voice")

      # Not a nicety: this is the one control in the app that changes what other
      # people experience.
      assert html =~ ~r/phx-click="greeting-publish"[^>]*data-claw-confirm/s
      assert html =~ "every caller hears"
    end

    test "with no engine, the wording is still editable but recording is not offered",
         %{conn: conn} do
      absent()
      {:ok, _view, html} = live(conn, ~p"/voice")

      assert html =~ ~r/phx-click="greeting-publish"[^>]*disabled/s
      assert html =~ "The wording can be saved without it"
    end

    test "a blank greeting resets rather than silencing the phone line", %{conn: conn} do
      absent()
      {:ok, view, _html} = live(conn, ~p"/voice")

      view
      |> form("form[phx-submit=greeting-save]", %{"greeting" => "   "})
      |> render_submit()

      assert Greeting.text() == Greeting.default_text()
    end
  end

  defp stub_writing_wav(root) do
    fixture = Path.join(root, "fixture.wav")
    File.write!(fixture, wav_bytes())

    path = Path.join(root, "voxcpm-stub")

    # Handles both shapes the app uses: `design --output FILE` and
    # `batch --input LINES --output-dir DIR`, the latter numbering outputs from 1
    # by line position exactly as voxcpm's own cli.py does.
    script = """
    #!/bin/sh
    out=""
    inp=""
    outdir=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--output" ]; then out="$2"; fi
      if [ "$1" = "--input" ]; then inp="$2"; fi
      if [ "$1" = "--output-dir" ]; then outdir="$2"; fi
      shift
    done
    if [ -n "$out" ]; then cp "#{fixture}" "$out"; fi
    if [ -n "$inp" ] && [ -n "$outdir" ]; then
      i=1
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        cp "#{fixture}" "$outdir/output_$(printf '%03d' $i).wav"
        i=$((i+1))
      done < "$inp"
    fi
    exit 0
    """

    File.write!(path, script)

    File.chmod!(path, 0o755)
    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
    path
  end

  defp wav_bytes do
    rate = 22_050
    data = :binary.copy(<<0::little-signed-16>>, div(rate, 10))
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end

  defp absent do
    Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
    Engine.refresh()
  end

  defp stub(exit_code \\ 0) do
    path = Path.join(System.tmp_dir!(), "voxcpm_stub_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nexit #{exit_code}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
    path
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
