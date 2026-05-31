defmodule BusterClaw.LibraryArtifactWorkspaceTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Library.Artifact

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-workspace-test-#{System.unique_integer([:positive])}"
      )

    library_root = Path.join(base, "library")

    prev_lib = Application.get_env(:buster_claw, :library_root)
    prev_ws = Application.get_env(:buster_claw, :workspace_root)

    Application.put_env(:buster_claw, :library_root, library_root)
    Application.delete_env(:buster_claw, :workspace_root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, prev_lib)
      if prev_ws, do: Application.put_env(:buster_claw, :workspace_root, prev_ws)
      File.rm_rf(base)
    end)

    %{base: base, library_root: library_root}
  end

  test "workspace_root falls back to the parent of the library root", %{base: base} do
    assert Artifact.workspace_root() == Path.expand(base)
  end

  test "workspace_root honours an explicit :workspace_root config" do
    explicit = Path.join(System.tmp_dir!(), "explicit-ws-#{System.unique_integer([:positive])}")
    Application.put_env(:buster_claw, :workspace_root, explicit)
    assert Artifact.workspace_root() == Path.expand(explicit)
  end

  test "ensure_workspace_dirs scaffolds library tree plus sibling dirs", %{
    base: base,
    library_root: library_root
  } do
    assert :ok = Artifact.ensure_workspace_dirs()

    assert File.dir?(Path.join(library_root, "raw"))
    assert File.dir?(Path.join(library_root, "reports"))

    for sub <- Artifact.workspace_subdirs() do
      assert File.dir?(Path.join(base, sub)), "expected #{sub}/ under workspace"
    end
  end
end
