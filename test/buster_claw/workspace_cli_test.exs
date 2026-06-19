defmodule BusterClaw.WorkspaceCLITest do
  use ExUnit.Case, async: false

  alias BusterClaw.WorkspaceCLI

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-workspace-cli-#{System.unique_integer([:positive])}"
      )

    real_cli = Path.join(root, "real-buster-claw")
    File.mkdir_p!(root)
    File.write!(real_cli, "#!/bin/sh\nexit 0\n")
    File.chmod!(real_cli, 0o755)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    prev_cli_path = System.get_env("BUSTER_CLAW_CLI_PATH")
    prev_cli = System.get_env("BUSTER_CLAW_CLI")

    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    System.put_env("BUSTER_CLAW_CLI_PATH", real_cli)
    System.delete_env("BUSTER_CLAW_CLI")

    on_exit(fn ->
      if prev_ws, do: Application.put_env(:buster_claw, :workspace_root, prev_ws)
      if prev_lib, do: Application.put_env(:buster_claw, :library_root, prev_lib)
      restore_env("BUSTER_CLAW_CLI_PATH", prev_cli_path)
      restore_env("BUSTER_CLAW_CLI", prev_cli)
      File.rm_rf(root)
    end)

    %{root: root, real_cli: real_cli}
  end

  test "installs an executable launcher in the workspace", %{root: root, real_cli: real_cli} do
    assert {:ok, path} = WorkspaceCLI.ensure()
    assert path == Path.join(root, "buster-claw")
    assert File.exists?(path)

    stat = File.stat!(path)
    assert Bitwise.band(stat.mode, 0o111) != 0

    content = File.read!(path)
    assert content =~ "BUSTER_CLAW_GENERATED_CLI_LAUNCHER=1"
    assert content =~ "exec '#{real_cli}' \"$@\""
  end

  test "updates a prior generated launcher", %{root: root} do
    path = Path.join(root, "buster-claw")
    File.write!(path, "#!/bin/sh\n# BUSTER_CLAW_GENERATED_CLI_LAUNCHER=1\nexit 1\n")

    assert {:ok, ^path} = WorkspaceCLI.ensure()
    assert File.read!(path) =~ "exec "
  end

  test "does not overwrite a user-owned launcher", %{root: root} do
    path = Path.join(root, "buster-claw")
    File.write!(path, "#!/bin/sh\necho custom\n")

    assert {:error, :launcher_exists} = WorkspaceCLI.ensure()
    assert File.read!(path) == "#!/bin/sh\necho custom\n"
  end

  test "the release launcher evals valid one-line Elixir (no collapsed multi-line case)",
       %{root: root} do
    # Force the release target: unset the explicit CLI path and point RELEASE_ROOT
    # at a fake bundled release binary.
    System.delete_env("BUSTER_CLAW_CLI_PATH")
    release_bin = Path.join([root, "bin", "buster_claw"])
    File.mkdir_p!(Path.dirname(release_bin))
    File.write!(release_bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(release_bin, 0o755)
    prev_release_root = System.get_env("RELEASE_ROOT")
    System.put_env("RELEASE_ROOT", root)
    on_exit(fn -> restore_env("RELEASE_ROOT", prev_release_root) end)

    assert {:ok, path} = WorkspaceCLI.ensure()
    content = File.read!(path)
    assert content =~ "eval '"

    [_, eval] = Regex.run(~r/eval '([^']*)'/, content)
    # The old launcher collapsed the multi-line case to spaces — a SyntaxError.
    # The eval must parse as valid Elixir.
    assert {:ok, _ast} = Code.string_to_quoted(eval)
    assert eval =~ "BusterClaw.CLI.main"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
