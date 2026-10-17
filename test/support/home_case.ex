defmodule BusterClawWeb.HomeCase do
  @moduledoc """
  The case for every test that mounts the work area (`StatusLive` at `/`).

  One setup, in one place: a throwaway workspace root (the trusted-senders file
  lives there) and a forced agent CLI, so nothing asserted about the home shell
  depends on whether the host machine has `claude` on PATH — CI runners don't.
  `async: false` because the workspace root is a global.

  `status_live_test.exs` was 2,044 lines and every panel's tests shared this
  block; the split by panel (10-16, CODE_QUALITY_SWEEP Phase 9) is what made the
  block worth naming.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use BusterClawWeb.ConnCase, async: false

      import Phoenix.LiveViewTest
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "bc_status_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end
end
