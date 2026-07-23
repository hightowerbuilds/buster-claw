defmodule BusterClaw.BrowserControlTest do
  @moduledoc """
  The live engine probe — launches a real Chromium-family browser.

  Excluded by default (`test/test_helper.exs`); run with

      mix test --include browser_engine

  on a machine with Chrome/Brave/Edge/Chromium installed. This is the dev-side
  half of Phase 0; the packaged-app smoke runs the same `probe/1`.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.CDP

  @moduletag :browser_engine
  @moduletag timeout: 60_000

  test "probe drives the full path: launch → navigate → read back → clean exit" do
    assert {:ok, report} = BrowserControl.probe()

    assert report.title == "bc-probe"
    assert report.product =~ ~r/(Chrome|Brave|Edg|Chromium)/
    assert is_integer(report.os_pid)
    # A clean Browser.close, not a kill backstop.
    assert report.exit_status == 0

    # No orphan: the engine process is really gone.
    refute os_process_alive?(report.os_pid)

    # No listening socket: the transport is a pipe (acceptance criterion 3).
    # The engine already exited, so its pid holds no sockets by construction —
    # the meaningful in-flight assertion lives in the CDP suite below.
  end

  test "no CDP socket exists while the engine is running" do
    {:ok, browser} = BrowserControl.detect()
    profile = Path.join(System.tmp_dir!(), "bc_sock_#{System.unique_integer([:positive])}")
    File.mkdir_p!(profile)

    {:ok, pid} = CDP.start_link(browser_path: browser, profile_dir: profile)

    try do
      assert {:ok, _} = CDP.command(pid, "Browser.getVersion")

      os_pid = CDP.os_pid(pid)
      {out, _} = System.cmd("lsof", ["-a", "-p", to_string(os_pid), "-iTCP", "-sTCP:LISTEN"])

      assert out == "", "engine has a listening TCP socket:\n#{out}"
    after
      CDP.stop(pid)
      File.rm_rf(profile)
    end
  end

  defp os_process_alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  end
end
