defmodule BusterClaw.Appearance.ShaderApprovalTest do
  @moduledoc """
  The approval store — `AGENT_APPLIED_SHADERS_ROADMAP` Phase 1.

  What these hold is the property the whole feature rests on: **approval is by
  content, not by name.** A store keyed on names alone would let a run overwrite
  an approved file and apply it under a blessed name, which is the same
  file-write shortcut that made "no command authors a shader" insufficient.
  """
  # async: false — points the global :workspace_root at a tmp dir and writes
  # app_settings rows through the shared Settings store.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Appearance
  alias BusterClaw.Appearance.ShaderApproval
  alias BusterClaw.Settings

  setup do
    root = Path.join(System.tmp_dir!(), "bc_approval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "shaders"))
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_shader(root, name, body \\ "vec4<f32>(1.0)") do
    File.write!(
      Path.join([root, "shaders", name <> ".wgsl"]),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return #{body}; }\n"
    )
  end

  # The backfill runs on first access and would approve anything already on
  # disk, which hides every case below. Stamping it first is how a test asks
  # about a shader that arrived AFTER the operator's existing set.
  defp skip_backfill do
    Settings.put("shader_approvals_backfilled_at", "1970-01-01T00:00:00Z")
  end

  describe "approving by content" do
    test "an approved shader stays approved while its bytes do not change", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")

      refute ShaderApproval.approved?("nebula")
      assert {:ok, hash} = ShaderApproval.approve("nebula")
      assert ShaderApproval.approved?("nebula")

      # Re-reading is not re-approving: the answer is derived from the file each
      # time, so a second call cannot drift from the first.
      assert ShaderApproval.approvals()["nebula"] == hash
      assert ShaderApproval.approved?("nebula")
    end

    test "editing the file revokes it — the whole point of the hash", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")
      {:ok, _} = ShaderApproval.approve("nebula")

      write_shader(root, "nebula", "vec4<f32>(0.5)")

      refute ShaderApproval.approved?("nebula"),
             "a name-keyed store would still say yes, and that is the attack"
    end

    test "deleting and rewriting does not inherit approval", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")
      {:ok, _} = ShaderApproval.approve("nebula")

      File.rm!(Path.join([root, "shaders", "nebula.wgsl"]))
      refute ShaderApproval.approved?("nebula")

      write_shader(root, "nebula", "vec4<f32>(0.25)")
      refute ShaderApproval.approved?("nebula")
    end

    test "approval does not leak between names", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")
      write_shader(root, "aurora")

      {:ok, _} = ShaderApproval.approve("nebula")

      assert ShaderApproval.approved?("nebula")
      refute ShaderApproval.approved?("aurora")
    end

    test "a shader that cannot be served cannot be approved", %{root: root} do
      skip_backfill()
      # No fs_main — `Shaders.read/1` refuses it, so there are no bytes that
      # would render and nothing honest to approve.
      File.write!(Path.join([root, "shaders", "broken.wgsl"]), "not a shader")

      assert {:error, :missing_fs_main} = ShaderApproval.approve("broken")
      refute ShaderApproval.approved?("broken")
    end

    test "an unknown shader is not approved, and neither is a non-binary" do
      skip_backfill()
      refute ShaderApproval.approved?("nope")
      refute ShaderApproval.approved?(nil)
      assert {:error, :invalid_name} = ShaderApproval.approve(nil)
    end

    test "revoke forgets one shader and leaves the others", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")
      write_shader(root, "aurora")
      {:ok, _} = ShaderApproval.approve("nebula")
      {:ok, _} = ShaderApproval.approve("aurora")

      :ok = ShaderApproval.revoke("nebula")

      refute ShaderApproval.approved?("nebula")
      assert ShaderApproval.approved?("aurora")
    end
  end

  describe "the backfill" do
    test "approves what was already there, once", %{root: root} do
      write_shader(root, "nebula")
      write_shader(root, "aurora")

      # Roadmap VIII.3: these predate the question, so the feature works on day
      # one instead of after 22 clicks.
      assert ShaderApproval.approved?("nebula")
      assert ShaderApproval.approved?("aurora")

      # A shader that arrives AFTER is new, and needs its click.
      write_shader(root, "written-by-the-model")
      refute ShaderApproval.approved?("written-by-the-model")
    end

    test "a cleared approval set does not re-approve everything", %{root: root} do
      write_shader(root, "nebula")
      assert ShaderApproval.approved?("nebula")

      :ok = ShaderApproval.revoke("nebula")

      # The marker is a separate key precisely so this cannot happen: collapsing
      # "no approvals" into "never backfilled" would turn every revocation into
      # a no-op on the next read.
      refute ShaderApproval.approved?("nebula")
    end

    test "a shaderface is never approved — it is not a background", %{root: root} do
      write_shader(root, "hightowerbuilds-face")
      write_shader(root, "nebula")

      assert ShaderApproval.approved?("nebula")
      refute Map.has_key?(ShaderApproval.approvals(), "hightowerbuilds-face")
    end

    test "a corrupt store fails closed rather than crashing", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")
      {:ok, _} = ShaderApproval.approve("nebula")

      Settings.put("shader_approvals", "{not json")

      assert ShaderApproval.approvals() == %{}
      refute ShaderApproval.approved?("nebula")
    end
  end

  describe "the delegation Appearance exposes" do
    test "the command layer's three entry points route to this store", %{root: root} do
      skip_backfill()
      write_shader(root, "nebula")

      refute Appearance.shader_approved?("nebula")
      assert {:ok, _hash} = Appearance.approve_shader("nebula")
      assert Appearance.shader_approved?("nebula")
      assert Map.has_key?(Appearance.approved_shaders(), "nebula")
    end
  end
end
