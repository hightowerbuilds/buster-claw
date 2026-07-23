defmodule BusterClaw.BrowserControl.LaunchTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Launch

  @browser "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

  defp argv(opts \\ []) do
    Launch.argv(@browser, Keyword.merge([profile_dir: "/tmp/p"], opts))
  end

  test "shape: sh -c shim, then the browser as $0, then flags" do
    assert ["-c", shim, @browser | flags] = argv()
    assert shim == Launch.shim()
    assert Enum.all?(flags, &is_binary/1)
  end

  test "transport is the pipe — and no debug port, ever" do
    flags = argv()

    assert "--remote-debugging-pipe" in flags
    refute Enum.any?(flags, &String.starts_with?(&1, "--remote-debugging-port"))
  end

  test "the shim wires fd3/fd4 before silencing the engine's own streams" do
    # Order matters: fd4 must dup the ORIGINAL stdout before fd1 is redirected,
    # or CDP responses land in /dev/null.
    assert Launch.shim() == ~S(exec "$0" "$@" 3<&0 4>&1 1>/dev/null 2>&1)
  end

  test "a dedicated profile dir is required and passed through" do
    assert "--user-data-dir=/tmp/p" in argv()

    assert_raise KeyError, fn ->
      Launch.argv(@browser, [])
    end
  end

  test "headless by default, headful on request" do
    assert "--headless=new" in argv()
    refute "--headless=new" in argv(headless: false)
  end

  test "never passes --enable-automation" do
    for opts <- [[], [headless: false]] do
      refute "--enable-automation" in argv(opts)
    end
  end

  test "hygiene flags are all present" do
    flags = argv()

    for flag <- Launch.hygiene_flags() do
      assert flag in flags
    end

    # The flag list is part of the privacy claim — pin the load-bearing ones so
    # a refactor can't silently drop them.
    for required <- [
          "--disable-background-networking",
          "--disable-sync",
          "--disable-component-update",
          "--metrics-recording-only"
        ] do
      assert required in Launch.hygiene_flags()
    end
  end

  test "window size renders into one flag" do
    assert "--window-size=800,600" in argv(window_size: {800, 600})
    assert "--window-size=1280,900" in argv()
  end
end
