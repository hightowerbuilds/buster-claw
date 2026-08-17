defmodule BusterClaw.Sketch.AssetsTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Sketch.{Assets, Document, Store}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAFElEQVR4nGP8" <>
           "z8Dwn4GBgYEJRAAAHAAD/1a0lqcAAAAASUVORK5CYII="
       )
  @gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  setup do
    root = Path.join(System.tmp_dir!(), "bc_assets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "storing bytes" do
    test "writes the image and reports what it is" do
      assert {:ok, asset} = Assets.put_binary("plan", @png)

      assert asset.format == :png
      assert asset.width == 2
      assert asset.height == 3
      assert asset.source =~ ~r/\A[0-9a-f]{16}\.png\z/
    end

    test "the sidecar sits beside the sketch, named after it" do
      {:ok, _} = Assets.put_binary("plan", @png)
      {:ok, dir} = Assets.dir("plan")

      assert Path.basename(dir) == "plan.assets"
      assert Path.dirname(dir) == Store.dir()
    end

    test "the same bytes twice write one file" do
      # Content-naming is the dedupe. Two elements point at one file and nothing
      # has to track references.
      {:ok, first} = Assets.put_binary("plan", @png)
      {:ok, second} = Assets.put_binary("plan", @png)

      assert first.source == second.source
      assert Assets.list("plan") == [first.source]
    end

    test "different images get different names" do
      {:ok, png} = Assets.put_binary("plan", @png)
      {:ok, gif} = Assets.put_binary("plan", @gif)

      assert png.source != gif.source
      assert length(Assets.list("plan")) == 2
    end

    test "the extension comes from the bytes, not from anything a caller said" do
      # A JPEG named `.png` is stored as `.jpg` and will be served as
      # image/jpeg. Believing the name is how a route ends up lying about a
      # content type.
      jpeg = <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 8, 7::16, 5::16, 3, 0xFF, 0xD9>>

      assert {:ok, %{source: source, format: :jpeg}} = Assets.put_binary("plan", jpeg)
      assert String.ends_with?(source, ".jpg")
    end
  end

  describe "refusing before anything is written" do
    test "a file that is not an image never reaches the workspace" do
      assert {:error, :unsupported} = Assets.put_binary("plan", "#!/bin/sh\nrm -rf /")
      assert {:error, :unsupported} = Assets.put_binary("plan", "<svg onload=alert(1)></svg>")

      # The point of "before": no directory, no partial file, nothing to clean up.
      assert Assets.list("plan") == []
      {:ok, dir} = Assets.dir("plan")
      refute File.exists?(dir)
    end

    test "empty and oversized" do
      assert {:error, :empty} = Assets.put_binary("plan", "")

      huge = @png <> :binary.copy(<<0>>, Assets.max_bytes())
      assert {:error, :too_large} = Assets.put_binary("plan", huge)
    end

    test "a bad sketch name is refused, so the sidecar cannot escape either" do
      assert {:error, :invalid_name} = Assets.put_binary("../escape", @png)
      assert {:error, :invalid_name} = Assets.dir("nested/name")
    end
  end

  describe "storing a file from disk — the packaged app's drop path" do
    @describetag :tmp_dir

    test "reads and stores it", %{tmp_dir: dir} do
      path = Path.join(dir, "shot.png")
      File.write!(path, @png)

      assert {:ok, %{format: :png, width: 2}} = Assets.put_file("plan", path)
    end

    test "refuses a non-image without reading it whole", %{tmp_dir: dir} do
      path = Path.join(dir, "not-really.png")
      File.write!(path, "PK\x03\x04 this is a zip")

      assert {:error, :unsupported} = Assets.put_file("plan", path)
      assert Assets.list("plan") == []
    end

    test "a missing path and a directory", %{tmp_dir: dir} do
      assert {:error, :not_found} = Assets.put_file("plan", Path.join(dir, "nope.png"))
      assert {:error, _} = Assets.put_file("plan", dir)
    end
  end

  describe "resolving one back for the route" do
    test "returns the path and the media type" do
      {:ok, %{source: source}} = Assets.put_binary("plan", @png)

      assert {:ok, path, "image/png"} = Assets.resolve("plan", source)
      assert File.read!(path) == @png
    end

    test "only names this module minted resolve" do
      # An allowlist, not a traversal check: nothing shaped like a path matches
      # sixteen hex digits and a known extension, so there is nothing to strip.
      {:ok, _} = Assets.put_binary("plan", @png)

      for bad <- [
            "../../../etc/passwd",
            "../plan.json",
            "0123456789abcdef.svg",
            "0123456789abcdef.png/../../x",
            "ABCDEF0123456789.png",
            "plan.json"
          ] do
        assert {:error, :invalid_name} = Assets.resolve("plan", bad),
               "#{inspect(bad)} should not resolve"
      end
    end

    test "a well-formed name that is not there is not found" do
      assert {:error, :not_found} = Assets.resolve("plan", "0123456789abcdef.png")
    end

    test "one sketch cannot resolve another's assets" do
      {:ok, %{source: source}} = Assets.put_binary("plan", @png)

      assert {:error, :not_found} = Assets.resolve("other", source)
    end
  end

  describe "deleting" do
    test "removing a sketch removes its images with it" do
      # The whole argument for the sidecar (D11). Keeping one and dropping the
      # other would leave exactly the orphans the shared folder was rejected for.
      {:ok, _} = Store.save("plan", Document.new())
      {:ok, %{source: source}} = Assets.put_binary("plan", @png)
      assert {:ok, _, _} = Assets.resolve("plan", source)

      :ok = Store.delete("plan")

      assert Assets.list("plan") == []
      assert {:error, :not_found} = Assets.resolve("plan", source)
      {:ok, dir} = Assets.dir("plan")
      refute File.exists?(dir)
    end

    test "deleting a sketch that has no images is fine" do
      {:ok, _} = Store.save("bare", Document.new())

      assert :ok = Store.delete("bare")
    end
  end
end
