defmodule BusterClaw.Pockets.FacesTest do
  # async: false — points the global :workspace_root / :library_root at tmp dirs,
  # exactly as `BusterClaw.PocketsTest` does and for the same reason.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Library
  alias BusterClaw.Pockets
  alias BusterClaw.Pockets.Faces

  setup do
    root = Path.join(System.tmp_dir!(), "bc_faces_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    :ok
  end

  # A face the browser would actually compile: the prelude is prepended there, so
  # the file itself is just the entry point. `Shaders.read/1` refuses one without
  # `fs_main`, which is why the body matters even in a test about URLs.
  defp wgsl(tag) do
    """
    @fragment
    fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
      return vec4<f32>(#{tag}, 0.0, 0.0, 1.0);
    }
    """
  end

  defp put_pocket_face(name) do
    Faces.ensure()
    File.write!(Path.join(Pockets.pocket_dir(Faces.pocket_name()), name <> ".wgsl"), wgsl("1.0"))
  end

  defp put_workspace_shader(name) do
    dir = BusterClaw.Shaders.dir()
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".wgsl"), wgsl("0.5"))
  end

  describe "ensure/0" do
    test "creates the Pocket with a manifest, so its files are servable" do
      assert :ok = Faces.ensure()
      assert File.exists?(Pockets.manifest_path(Faces.pocket_name()))
      assert {:ok, _pocket} = Pockets.load(Faces.pocket_name())
    end

    test "never overwrites a manifest the operator edited" do
      Faces.ensure()
      path = Pockets.manifest_path(Faces.pocket_name())
      File.write!(path, "---\nname: contact-faces\n---\n\nMine.\n")

      Faces.ensure()

      assert File.read!(path) =~ "Mine."
    end
  end

  describe "source_url/1 resolution order" do
    test "the Pocket wins over a workspace shader of the same name" do
      put_workspace_shader("swirl")
      put_pocket_face("swirl")

      url = Faces.source_url("swirl")

      assert url =~ "/pockets/contact-faces/swirl.wgsl"
      refute url =~ "/shaders/"
    end

    test "falls back to <workspace>/shaders when the Pocket has no such face" do
      put_workspace_shader("swirl")
      Faces.ensure()

      assert Faces.source_url("swirl") == "/shaders/swirl"
    end

    test "a face the Pocket holds resolves even with no workspace shaders at all" do
      put_pocket_face("ember")

      assert Faces.source_url("ember") =~ "/pockets/contact-faces/ember.wgsl"
    end

    test "a name held nowhere is nil, which is the generative face" do
      Faces.ensure()

      assert Faces.source_url("gone") == nil
    end

    test "a manifest-less contact-faces folder serves nothing" do
      # The edge stated in the moduledoc: `Pockets.resolve/2` refuses a Pocket
      # that does not load, so listing its files would promise bytes the asset
      # route answers 404 to.
      dir = Pockets.pocket_dir(Faces.pocket_name())
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "orphan.wgsl"), wgsl("1.0"))

      assert Faces.source_url("orphan") == nil
      assert Faces.list() == []
    end

    test "a symlinked face is refused rather than followed" do
      # This is the one guard here that is a security property rather than a
      # behaviour. A mount is how a Pocket reaches outside itself and it is the
      # ONLY way — `Pockets.Mounts` exists to make that reach a registered,
      # revocable thing. A face that followed a symlink would be a second, silent
      # way out, which is exactly the hole the mount design is built to close.
      # `Notes` refuses `:symlink` entries on `lstat` for the same reason.
      put_pocket_face("real")
      outside = Path.join(System.tmp_dir!(), "bc_faces_outside_#{System.unique_integer()}.wgsl")
      File.write!(outside, wgsl("1.0"))
      File.ln_s!(outside, Path.join(Pockets.pocket_dir(Faces.pocket_name()), "linked.wgsl"))
      on_exit(fn -> File.rm(outside) end)

      assert Faces.source_url("linked") == nil
      assert Faces.list() == ["real"]
    end

    test "a non-binary name is nil rather than a crash" do
      assert Faces.source_url(nil) == nil
    end
  end

  describe "list/0 and choices/0" do
    test "list/0 is the Pocket's .wgsl files, without extensions" do
      put_pocket_face("ember")
      put_pocket_face("ash")
      File.write!(Path.join(Pockets.pocket_dir(Faces.pocket_name()), "notes.txt"), "hi")

      assert Faces.list() == ["ash", "ember"]
    end

    test "choices/0 merges both sources and de-duplicates a shared name" do
      put_pocket_face("swirl")
      put_pocket_face("ember")
      put_workspace_shader("swirl")
      put_workspace_shader("drift")

      choices = Faces.choices()

      assert choices == ["drift", "ember", "swirl"]
      # De-duplicated, not merely sorted — a picker cannot express which of two
      # identical `swirl` options it means, because `face_shader` stores a name.
      assert length(choices) == length(Enum.uniq(choices))
    end
  end
end
