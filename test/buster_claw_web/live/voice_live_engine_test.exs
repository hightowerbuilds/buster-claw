defmodule BusterClawWeb.VoiceLiveEngineTest do
  @moduledoc """
  The engine panel, which reports on a binary that is not installed here and
  cannot be. Application env steers resolution, which is global, so this cannot
  be async and cannot live in `voice_live_test.exs` beside the async cases.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Voice.Chimes
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
    # Nothing to run when there is nothing installed.
    refute html =~ "engine-verify"
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

  test "an installed engine reports its path and device, and offers to run it", %{conn: conn} do
    path = stub()

    {:ok, _view, html} = live(conn, ~p"/voice")

    assert html =~ path
    assert html =~ "engine-verify"
    # The install instructions are for people who need them.
    refute html =~ "pip install voxcpm"
  end

  test "Check again re-reads the disk, which is the whole point of it", %{conn: conn} do
    absent()
    {:ok, view, html} = live(conn, ~p"/voice")
    assert html =~ "Not installed"

    # Install it underneath, exactly as an operator would while the page is open.
    stub()

    html = view |> element("button[phx-click=engine-recheck]") |> render_click()

    assert html =~ "engine-verify"
    refute html =~ "Not installed"
  end

  test "Run it reports what the binary actually did", %{conn: conn} do
    stub(3)
    {:ok, view, _html} = live(conn, ~p"/voice")

    view |> element("button[phx-click=engine-verify]") |> render_click()

    # The task result arrives as a message; render/1 after it lands.
    assert eventually(fn -> render(view) =~ "exited 3" end),
           "expected the failing exit status to reach the page"
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

    File.write!(
      path,
      "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"--output\" ]; then out=\"$2\"; fi\n  shift\ndone\ncp \"#{fixture}\" \"$out\"\nexit 0\n"
    )

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
