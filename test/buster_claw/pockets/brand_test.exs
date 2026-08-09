defmodule BusterClaw.Pockets.BrandTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Library, Pockets}
  alias BusterClaw.Pockets.{Brand, Operator}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_brand_#{System.unique_integer([:positive])}")
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

    {:ok, root: root}
  end

  defp upload(role, name \\ "art.png") do
    src = Path.join(System.tmp_dir!(), "bc_src_#{System.unique_integer([:positive])}_#{name}")
    File.write!(src, "image-bytes")
    on_exit(fn -> File.rm_rf(src) end)
    Brand.put(role, src, name)
  end

  # Drop a file straight into the Pocket, the way Finder would — bypassing the
  # app entirely. This is the case the error exists for.
  defp drop_in(role, name) do
    pocket = Brand.slot(role).pocket
    File.mkdir_p!(Pockets.pocket_dir(pocket))
    File.write!(Path.join(Pockets.pocket_dir(pocket), name), "other-bytes")
  end

  describe "the three states" do
    test "an absent pocket shows the shipped default" do
      assert Brand.status("nav_home") == :default
      assert Brand.image_url("nav_home") == "/images/brand/home-icon.png"
    end

    test "exactly one image shows that image" do
      assert {:ok, _} = upload("nav_home")

      assert Brand.status("nav_home") == :custom
      assert Brand.image_url("nav_home") =~ ~r"^/pockets/nav-home/nav-home\.png\?v="
    end

    test "two or more images show TEXT, not the default and not a guess" do
      assert {:ok, _} = upload("nav_home")
      drop_in("nav_home", "extra.png")

      assert {:error, :too_many, 2} = Brand.status("nav_home")

      # nil is the signal to render the label. Falling back to the shipped
      # default here would hide the problem completely — the dock would look
      # right and the stray file would sit there forever.
      assert Brand.image_url("nav_home") == nil
      assert Brand.label("nav_home") == "Home"
    end

    test "removing the extra image restores the art with no repair step" do
      {:ok, _} = upload("nav_home")
      drop_in("nav_home", "extra.png")
      assert {:error, :too_many, 2} = Brand.status("nav_home")

      File.rm!(Path.join(Pockets.pocket_dir("nav-home"), "extra.png"))

      # Nothing was stored, so nothing has to be cleared.
      assert Brand.status("nav_home") == :custom
      assert Brand.image_url("nav_home")
    end

    test "non-image files in the pocket are not counted as art" do
      {:ok, _} = upload("nav_home")
      drop_in("nav_home", "notes.txt")

      assert Brand.status("nav_home") == :custom
    end

    test "a folder made by hand with no POCKET.md is inert, and that is deliberate" do
      # Documenting a real edge rather than hiding it. Serving goes through
      # `Pockets.resolve/2`, which refuses a Pocket that does not load — so art in
      # a manifest-less folder could be *listed* but never *served*, and showing
      # it in the tab would promise something the asset route would 404.
      #
      # The route in is "Add art" (D12), which writes the manifest. Once it
      # exists, dropping files in from Finder behaves exactly as the tests above.
      drop_in("nav_home", "hand-made.png")

      refute File.exists?(Pockets.manifest_path("nav-home"))
      assert Brand.status("nav_home") == :default
    end
  end

  describe "upload and clear" do
    test "upload replaces rather than adds, so it can never cause the error" do
      {:ok, _} = upload("nav_home", "first.png")
      {:ok, _} = upload("nav_home", "second.jpg")

      assert Brand.status("nav_home") == :custom
    end

    test "uploading is also the way OUT of an over-full pocket" do
      {:ok, _} = upload("nav_home")
      drop_in("nav_home", "extra.png")
      assert {:error, :too_many, 2} = Brand.status("nav_home")

      {:ok, _} = upload("nav_home", "chosen.png")
      assert Brand.status("nav_home") == :custom
    end

    test "clear returns the slot to the shipped default but keeps the manifest" do
      {:ok, _} = upload("nav_home")
      assert :ok = Brand.clear("nav_home")

      assert Brand.status("nav_home") == :default
      assert Brand.image_url("nav_home") == "/images/brand/home-icon.png"
      assert File.exists?(Pockets.manifest_path("nav-home"))
    end

    test "a non-image upload is refused" do
      src = Path.join(System.tmp_dir!(), "bc_bad_#{System.unique_integer([:positive])}.exe")
      File.write!(src, "nope")
      on_exit(fn -> File.rm_rf(src) end)

      assert {:error, :unsupported_type} = Brand.put("nav_home", src, "nope.exe")
    end

    test "an unknown role is refused rather than silently creating a pocket" do
      src = Path.join(System.tmp_dir!(), "bc_x_#{System.unique_integer([:positive])}.png")
      File.write!(src, "x")
      on_exit(fn -> File.rm_rf(src) end)

      assert {:error, :unknown_role} = Brand.put("nav_nonexistent", src, "x.png")
      assert {:error, :unknown_role} = Brand.clear("nav_nonexistent")
    end
  end

  describe "the shipped defaults are never copied out (D13)" do
    test "no brand pocket exists until the operator adds art" do
      for slot <- Brand.slots() do
        refute File.exists?(Pockets.pocket_dir(slot.pocket)),
               "#{slot.pocket} should not exist before an upload"
      end

      assert Pockets.list() == []
    end

    test "every shipped default is a real file in priv/static" do
      for slot <- Brand.slots() do
        path = Path.join([:code.priv_dir(:buster_claw), "static", slot.default])

        assert File.regular?(path),
               "#{slot.role}'s default #{slot.default} is missing from priv/static"
      end
    end
  end

  describe "binding is by fixed name (D10)" do
    test "a pocket that merely declares a brand role does not capture the slot" do
      # The agent can write POCKET.md, so a discovered binding would let it
      # shadow the app's chrome. Role `nav_home` is filled by `nav-home/` only.
      dir = Pockets.pocket_dir("imposter")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "POCKET.md"), ~s(---\nkind: icons\nroles: ["nav_home"]\n---\n))
      File.write!(Path.join(dir, "evil.png"), "bytes")

      assert Brand.status("nav_home") == :default
      assert Brand.image_url("nav_home") == "/images/brand/home-icon.png"
    end

    test "a brand pocket cannot be mounted away" do
      target = Path.join(System.tmp_dir!(), "bc_bt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(target)
      on_exit(fn -> File.rm_rf(target) end)

      {:ok, _} = upload("nav_home")

      assert {:error, :role_bound} = Operator.mount("nav-home", target)
    end
  end

  describe "the role table and Pockets.roles/0 agree" do
    test "every brand role is a known role, so it is refused for mounting" do
      known = Pockets.roles()

      for slot <- Brand.slots() do
        assert slot.role in known,
               "#{slot.role} is missing from Pockets.roles/0 — mounting it would be allowed"
      end
    end

    test "slots are unique in role, pocket name and default asset" do
      slots = Brand.slots()

      for key <- [:role, :pocket, :default] do
        values = Enum.map(slots, &Map.fetch!(&1, key))
        assert length(Enum.uniq(values)) == length(values), "duplicate #{key} in the slot table"
      end
    end
  end

  describe "overview" do
    test "reports what is filling each slot, with nil url exactly when in error" do
      {:ok, _} = upload("nav_home")
      {:ok, _} = upload("nav_workspace")
      drop_in("nav_workspace", "b.png")

      by_role = Map.new(Brand.overview(), &{&1.role, &1})

      assert %{status: :custom, count: 1, url: url} = by_role["nav_home"]
      assert url =~ "/pockets/nav-home/"

      assert %{status: {:error, :too_many, 2}, url: nil} = by_role["nav_workspace"]
      assert %{status: :default, count: 0} = by_role["home_banner"]
    end
  end
end
