defmodule BusterClaw.Commands.BrowserControlProbeTest do
  @moduledoc """
  The command wrapper's contract without a REAL engine: the probe's report is
  DATA either way (a diagnostic's failure detail is its result and must survive
  the API's error laundering), and the smoke script greps this exact shape.

  The failure path here is not simulated — a fake "engine" (a script that exits
  immediately) is pinned via `:browser_control_binary` and the probe runs for
  real: launch, port exit, pending-command failure, report mapping. The happy
  path against a live Chromium is `BusterClaw.BrowserControlTest` (tagged) and
  `scripts/smoke_desktop.sh` against the packaged app.
  """
  # async: false — steers detection via the global :browser_control_binary.
  use ExUnit.Case, async: false

  alias BusterClaw.Commands

  setup do
    root = Path.join(System.tmp_dir!(), "bc_probe_cmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :browser_control_binary)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:buster_claw, :browser_control_binary, prev),
        else: Application.delete_env(:buster_claw, :browser_control_binary)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "catalog: registered as a restricted trigger with no args" do
    entry = Enum.find(Commands.Catalog.entries(), &(&1.name == "browser_control_probe"))

    assert %{type: :trigger, tier: :restricted, args: args} = entry
    assert args == %{}
  end

  test "an engine that dies at launch yields ok: false with the step named", %{root: root} do
    fake = Path.join(root, "fake-chrome")
    File.write!(fake, "#!/bin/sh\nexit 7\n")
    File.chmod!(fake, 0o755)
    Application.put_env(:buster_claw, :browser_control_binary, fake)

    assert {:ok, %{ok: false, failed_step: step, reason: reason}} =
             Commands.Web.browser_control_probe()

    # The exit races the first calls: death can land at subscribe or at the
    # first command. Either way the report names the step and the cause — and
    # the prober itself must survive (no :noproc crash).
    assert step in [:subscribe, :version]
    assert reason =~ "browser_exited"
  end

  test "an engine that hangs without speaking CDP fails the version step", %{root: root} do
    fake = Path.join(root, "mute-chrome")
    # Alive but silent: never writes a CDP frame. The version command must
    # time out rather than block the prober forever; stop's TERM/KILL backstop
    # then reaps the process (sleep ignores Browser.close).
    File.write!(fake, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(fake, 0o755)
    Application.put_env(:buster_claw, :browser_control_binary, fake)

    prev = Application.get_env(:buster_claw, :browser_control_probe_timeout_ms)
    Application.put_env(:buster_claw, :browser_control_probe_timeout_ms, 500)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:buster_claw, :browser_control_probe_timeout_ms, prev),
        else: Application.delete_env(:buster_claw, :browser_control_probe_timeout_ms)
    end)

    assert {:ok, %{ok: false, failed_step: :version, reason: reason}} =
             Commands.Web.browser_control_probe()

    assert reason =~ "timeout"
  end
end
