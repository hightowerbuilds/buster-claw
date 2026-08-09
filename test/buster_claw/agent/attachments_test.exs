defmodule BusterClaw.Agent.AttachmentsTest do
  # async: false — points the global :attachments_root at a tmp dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Agent.Attachments

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0>>
  @gif <<"GIF89a", 1, 0, 1, 0, 0x80, 0, 0>>
  @webp <<"RIFF", 26, 0, 0, 0, "WEBPVP8 ", 0, 0, 0, 0>>
  @pdf <<"%PDF-1.7\n1 0 obj\n">>
  @text "# notes\n\nplain words, nothing more.\n"
  # No magic number, a NUL, and a control byte: binary by inspection.
  @blob <<0x01, 0x02, 0x00, 0xFF, 0xFE, 0x03, 0x04>>

  setup do
    root = Path.join(System.tmp_dir!(), "bc_attach_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :attachments_root)
    Application.put_env(:buster_claw, :attachments_root, Path.join(root, "staging"))

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:buster_claw, :attachments_root)
        value -> Application.put_env(:buster_claw, :attachments_root, value)
      end

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp upload(name, media_type \\ "image/png") do
    %{filename: name, media_type: media_type, source: :upload}
  end

  defp dropped(name, media_type \\ "image/png") do
    %{filename: name, media_type: media_type, source: :native_path}
  end

  defp source_file(root, name, contents) do
    path = Path.join(root, name)
    File.write!(path, contents)
    path
  end

  describe "stage/3 from bytes" do
    test "writes the bytes and returns the contract's shape" do
      assert {:ok, att} = Attachments.stage("conv-a", upload("shot.png"), @png)

      assert Enum.sort(Map.keys(att)) ==
               Enum.sort([
                 :id,
                 :conversation_id,
                 :filename,
                 :media_type,
                 :kind,
                 :bytes,
                 :path,
                 :source
               ])

      assert att.conversation_id == "conv-a"
      assert att.filename == "shot.png"
      assert att.media_type == "image/png"
      assert att.kind == :image
      assert att.bytes == byte_size(@png)
      assert att.source == :upload
      assert File.read!(att.path) == @png
    end

    test "a bare binary is bytes, never a path", %{root: root} do
      bait = source_file(root, "bait.png", @png)

      # The bare-binary payload must be staged as its own content — if it were
      # ever treated as a path, the staged file would be the PNG's bytes.
      assert {:ok, att} = Attachments.stage("conv-a", upload("x.txt", "text/plain"), bait)
      assert File.read!(att.path) == bait
      assert att.kind == :text
    end

    test "stages into the conversation's own directory" do
      {:ok, dir} = Attachments.dir("conv-a")
      {:ok, att} = Attachments.stage("conv-a", upload("shot.png"), @png)

      assert Path.dirname(att.path) == dir
      assert att.path == Path.join(dir, att.id <> ".png")
    end

    test "refuses an empty file" do
      assert {:error, :empty} = Attachments.stage("conv-a", upload("nothing.png"), "")
    end

    test "refuses a payload that is neither bytes nor a path" do
      assert {:error, :invalid_payload} = Attachments.stage("conv-a", upload("x.png"), 42)
    end

    test "refuses an unknown source" do
      attrs = %{filename: "x.png", media_type: "image/png", source: :telepathy}
      assert {:error, :invalid_source} = Attachments.stage("conv-a", attrs, @png)
    end

    test "accepts string keys, because the client payload arrives decoded" do
      attrs = %{"filename" => "shot.png", "media_type" => "image/png", "source" => "upload"}
      assert {:ok, att} = Attachments.stage("conv-a", attrs, @png)
      assert att.filename == "shot.png"
      assert att.source == :upload
    end
  end

  describe "stage/3 from a path" do
    test "copies the file and records the native source", %{root: root} do
      path = source_file(root, "drop.png", @png)

      assert {:ok, att} = Attachments.stage("conv-a", dropped("drop.png"), {:path, path})
      assert att.source == :native_path
      assert att.kind == :image
      assert att.bytes == byte_size(@png)
      assert File.read!(att.path) == @png
      # The original is untouched: this is a copy, not a move.
      assert File.exists?(path)
    end

    test "refuses a relative path", %{root: root} do
      source_file(root, "drop.png", @png)

      assert {:error, :invalid_path} =
               Attachments.stage("conv-a", dropped("d"), {:path, "drop.png"})
    end

    test "refuses a path with a NUL, which would otherwise raise in File.stat" do
      assert {:error, :invalid_path} =
               Attachments.stage("conv-a", dropped("d"), {:path, "/tmp/a\0b.png"})
    end

    test "refuses a directory" do
      assert {:error, :not_regular} =
               Attachments.stage("conv-a", dropped("d"), {:path, System.tmp_dir!()})
    end

    test "refuses a symlink rather than resolving it", %{root: root} do
      target = source_file(root, "real.png", @png)
      link = Path.join(root, "link.png")
      File.ln_s!(target, link)

      assert {:error, :not_regular} = Attachments.stage("conv-a", dropped("l.png"), {:path, link})
    end

    test "refuses a character device, so /dev/zero cannot be drained" do
      if File.exists?("/dev/zero") do
        assert {:error, :not_regular} =
                 Attachments.stage("conv-a", dropped("z"), {:path, "/dev/zero"})
      end
    end

    test "refuses a path that does not exist" do
      assert {:error, :not_found} =
               Attachments.stage("conv-a", dropped("g"), {:path, "/nope/not/here.png"})
    end
  end

  describe "hostile filenames" do
    test "a traversal name stages inside the conversation directory" do
      {:ok, dir} = Attachments.dir("conv-a")
      assert {:ok, att} = Attachments.stage("conv-a", upload("../../etc/passwd"), @png)

      assert Path.dirname(att.path) == dir
      assert Path.expand(att.path) == att.path
      refute File.exists?("/tmp/etc/passwd")
      # Display-only, and cleaned for display: the path components are gone.
      assert att.filename == "passwd"
    end

    test "a name with a NUL stages, with the NUL out of the display name" do
      {:ok, dir} = Attachments.dir("conv-a")
      assert {:ok, att} = Attachments.stage("conv-a", upload("sh\0ot.png"), @png)

      assert Path.dirname(att.path) == dir
      refute String.contains?(att.filename, <<0>>)
      assert File.exists?(att.path)
    end

    test "a name that is a path stages inside the conversation directory" do
      {:ok, dir} = Attachments.dir("conv-a")
      assert {:ok, att} = Attachments.stage("conv-a", upload("/etc/hosts"), @png)

      assert Path.dirname(att.path) == dir
      assert att.filename == "hosts"
    end

    test "a 3000-character name stages, truncated for display" do
      {:ok, dir} = Attachments.dir("conv-a")
      long = String.duplicate("a", 3_000) <> ".png"

      assert {:ok, att} = Attachments.stage("conv-a", upload(long), @png)
      assert Path.dirname(att.path) == dir
      assert String.length(att.filename) <= 120
      assert byte_size(Path.basename(att.path)) < 40
    end

    test "a name that is a single dot stages under a generated name" do
      {:ok, dir} = Attachments.dir("conv-a")

      assert {:ok, att} = Attachments.stage("conv-a", upload("."), @png)
      assert Path.dirname(att.path) == dir
      assert Path.basename(att.path) == att.id <> ".png"
      assert att.filename == "attachment"
    end

    test "a name that is not valid UTF-8 stages under the fallback name" do
      assert {:ok, att} = Attachments.stage("conv-a", upload(<<0xFF, 0xFE, 0xFD>>), @png)
      assert att.filename == "attachment"
      assert File.exists?(att.path)
    end

    test "the on-disk name is generated, never the user's" do
      names = for _n <- 1..5, do: elem(Attachments.stage("conv-a", upload("same.png"), @png), 1)

      assert length(Enum.uniq(Enum.map(names, & &1.path))) == 5

      for att <- names do
        assert Regex.match?(~r/\A[A-Za-z0-9_-]+\.png\z/, Path.basename(att.path))
      end
    end
  end

  describe "the conversation id is a gate too" do
    test "refuses a traversal conversation id" do
      assert {:error, :invalid_conversation} =
               Attachments.stage("../../etc", upload("x.png"), @png)
    end

    test "refuses a conversation id with a slash or a NUL" do
      assert {:error, :invalid_conversation} = Attachments.stage("a/b", upload("x.png"), @png)
      assert {:error, :invalid_conversation} = Attachments.stage("a\0b", upload("x.png"), @png)
      assert {:error, :invalid_conversation} = Attachments.stage("", upload("x.png"), @png)
      assert {:error, :invalid_conversation} = Attachments.stage(:conv, upload("x.png"), @png)
    end

    test "list/1 and purge/1 answer harmlessly for a malformed id" do
      assert Attachments.list("../../etc") == []
      assert Attachments.purge("../../etc") == :ok
    end
  end

  describe "size caps" do
    test "refuses bytes over the per-file cap" do
      cap = Attachments.limits().max_file_bytes
      oversize = :binary.copy("a", cap + 1)

      assert {:error, :too_large} = Attachments.stage("conv-a", upload("big.txt"), oversize)
      assert Attachments.list("conv-a") == []
    end

    test "refuses an oversize path from the stat, without reading it", %{root: root} do
      huge = Path.join(root, "huge.bin")

      # A sparse file: 11 GB of apparent size costing a few KB of disk. If the
      # implementation read before it checked, this test would either take
      # minutes or exhaust memory — finishing fast IS the assertion.
      {:ok, fd} = :file.open(huge, [:write, :raw])
      {:ok, _pos} = :file.position(fd, 11 * 1024 * 1024 * 1024)
      :ok = :file.write(fd, "x")
      :ok = :file.close(fd)
      assert File.stat!(huge).size > 11 * 1024 * 1024 * 1024

      {micros, result} =
        :timer.tc(fn -> Attachments.stage("conv-a", dropped("huge.bin"), {:path, huge}) end)

      assert result == {:error, :too_large}
      assert micros < 2_000_000
      # Nothing was written on the way to refusing.
      assert Attachments.list("conv-a") == []
      {:ok, dir} = Attachments.dir("conv-a")
      assert File.ls(dir) in [{:error, :enoent}, {:ok, []}]
    end

    test "refuses once the conversation's total would be exceeded" do
      %{max_file_bytes: file_cap, max_conversation_bytes: total_cap} = Attachments.limits()
      chunk = :binary.copy("a", div(file_cap * 9, 10))
      fits = div(total_cap, byte_size(chunk))

      for n <- 1..fits do
        assert {:ok, _att} = Attachments.stage("conv-a", upload("f#{n}.txt", "text/plain"), chunk)
      end

      assert {:error, :conversation_full} =
               Attachments.stage("conv-a", upload("one-too-many.txt", "text/plain"), chunk)

      assert length(Attachments.list("conv-a")) == fits
    end

    test "refuses once the conversation's count is reached" do
      cap = Attachments.limits().max_conversation_count

      for n <- 1..cap do
        assert {:ok, _att} = Attachments.stage("conv-a", upload("f#{n}.png"), @png)
      end

      assert {:error, :too_many} = Attachments.stage("conv-a", upload("last.png"), @png)
      assert length(Attachments.list("conv-a")) == cap
    end

    test "the caps are per conversation, not global" do
      cap = Attachments.limits().max_conversation_count
      for n <- 1..cap, do: Attachments.stage("conv-a", upload("f#{n}.png"), @png)

      assert {:ok, _att} = Attachments.stage("conv-b", upload("fine.png"), @png)
    end
  end

  describe "classification by magic bytes" do
    test "a mislabelled media type is classified by what the bytes are" do
      # Claims PNG, is JPEG. `kind` picks the backend flag, so believing the
      # claim would hand a JPEG to a PNG-shaped path.
      assert {:ok, att} = Attachments.stage("conv-a", upload("lie.png", "image/png"), @jpeg)
      assert att.media_type == "image/jpeg"
      assert att.kind == :image
      assert Path.extname(att.path) == ".jpg"
    end

    test "a text file claiming to be an image is text" do
      assert {:ok, att} = Attachments.stage("conv-a", upload("lie.png", "image/png"), @text)
      assert att.kind == :text
      assert att.media_type == "text/plain"
      assert Path.extname(att.path) == ".txt"
    end

    test "a PNG claiming to be text is an image" do
      assert {:ok, att} = Attachments.stage("conv-a", upload("lie.txt", "text/plain"), @png)
      assert att.kind == :image
      assert att.media_type == "image/png"
    end

    test "recognises every image format the contract names" do
      for {bytes, expected} <- [
            {@png, "image/png"},
            {@jpeg, "image/jpeg"},
            {@gif, "image/gif"},
            {@webp, "image/webp"}
          ] do
        assert {:ok, att} =
                 Attachments.stage("conv-a", upload("x.bin", "application/x-lie"), bytes)

        assert att.media_type == expected
        assert att.kind == :image
      end
    end

    test "a PDF is binary, not an image" do
      assert {:ok, att} = Attachments.stage("conv-a", upload("doc.pdf", "application/pdf"), @pdf)
      assert att.kind == :binary
      assert att.media_type == "application/pdf"
      assert Path.extname(att.path) == ".pdf"
    end

    test "an unrecognised binary is octet-stream, whatever it claimed" do
      assert {:ok, att} = Attachments.stage("conv-a", upload("x.png", "image/png"), @blob)
      assert att.kind == :binary
      assert att.media_type == "application/octet-stream"
      assert Path.extname(att.path) == ".bin"
    end

    test "a declared text type survives only from the allowlist" do
      assert {:ok, md} = Attachments.stage("conv-a", upload("n.md", "text/markdown"), @text)
      assert md.media_type == "text/markdown"
      assert Path.extname(md.path) == ".md"

      assert {:ok, weird} = Attachments.stage("conv-a", upload("n.zzz", "text/zzz"), @text)
      assert weird.media_type == "text/plain"
      assert Path.extname(weird.path) == ".txt"

      assert {:ok, junk} = Attachments.stage("conv-a", upload("n.txt", "not a media type"), @text)
      assert junk.media_type == "text/plain"
    end

    test "text is staged too, even though its consumer inlines it" do
      assert {:ok, att} = Attachments.stage("conv-a", upload("n.md", "text/markdown"), @text)
      assert File.read!(att.path) == @text
    end

    test "multi-byte text cut by the sniff window still reads as text" do
      body = String.duplicate("é", 5_000)
      assert {:ok, att} = Attachments.stage("conv-a", upload("n.txt", "text/plain"), body)
      assert att.kind == :text
    end
  end

  describe "list/1 and get/2" do
    test "lists what was staged, and nothing from another conversation" do
      {:ok, a1} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, a2} = Attachments.stage("conv-a", upload("2.png"), @jpeg)
      {:ok, b1} = Attachments.stage("conv-b", upload("3.png"), @gif)

      assert Enum.sort(Enum.map(Attachments.list("conv-a"), & &1.id)) == Enum.sort([a1.id, a2.id])
      assert Enum.map(Attachments.list("conv-b"), & &1.id) == [b1.id]
    end

    test "round-trips every field through the sidecar", %{root: root} do
      path = source_file(root, "drop.md", @text)
      {:ok, att} = Attachments.stage("conv-a", dropped("drop.md", "text/markdown"), {:path, path})

      assert [listed] = Attachments.list("conv-a")
      assert listed == att
    end

    test "an empty or absent conversation lists nothing" do
      assert Attachments.list("conv-empty") == []
    end

    test "get/2 finds one by id" do
      {:ok, att} = Attachments.stage("conv-a", upload("1.png"), @png)
      assert {:ok, ^att} = Attachments.get("conv-a", att.id)
    end

    test "get/2 refuses another conversation's id" do
      {:ok, mine} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, theirs} = Attachments.stage("conv-b", upload("2.png"), @png)

      assert {:error, :not_found} = Attachments.get("conv-a", theirs.id)
      assert {:error, :not_found} = Attachments.get("conv-b", mine.id)
    end

    test "get/2 refuses a malformed id without looking outside the directory" do
      Attachments.stage("conv-a", upload("1.png"), @png)

      assert {:error, :not_found} = Attachments.get("conv-a", "../../etc/passwd")
      assert {:error, :not_found} = Attachments.get("conv-a", "a/b")
      assert {:error, :not_found} = Attachments.get("conv-a", <<"ok", 0>>)
      assert {:error, :not_found} = Attachments.get("conv-a", nil)
    end

    test "a hand-edited sidecar pointing outside its directory is ignored", %{root: root} do
      {:ok, att} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, dir} = Attachments.dir("conv-a")
      secret = source_file(root, "secret.txt", "not yours")

      meta = Path.join(dir, att.id <> ".meta.json")

      tampered =
        meta
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("file", Path.relative_to(secret, dir))

      File.write!(meta, Jason.encode!(tampered))

      assert Attachments.list("conv-a") == []
    end
  end

  describe "remove/2" do
    test "drops one and leaves the rest" do
      {:ok, a1} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, a2} = Attachments.stage("conv-a", upload("2.png"), @jpeg)

      assert :ok = Attachments.remove("conv-a", a1.id)
      refute File.exists?(a1.path)
      assert Enum.map(Attachments.list("conv-a"), & &1.id) == [a2.id]
    end

    test "takes the sidecar with it", %{root: _root} do
      {:ok, att} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, dir} = Attachments.dir("conv-a")

      assert :ok = Attachments.remove("conv-a", att.id)
      assert File.ls!(dir) == []
    end

    test "refuses another conversation's id" do
      {:ok, theirs} = Attachments.stage("conv-b", upload("1.png"), @png)

      assert {:error, :not_found} = Attachments.remove("conv-a", theirs.id)
      assert File.exists?(theirs.path)
    end
  end

  describe "purge/1" do
    test "removes everything for one conversation and nothing from another" do
      {:ok, a1} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, a2} = Attachments.stage("conv-a", upload("2.png"), @jpeg)
      {:ok, b1} = Attachments.stage("conv-b", upload("3.png"), @gif)

      assert :ok = Attachments.purge("conv-a")

      refute File.exists?(a1.path)
      refute File.exists?(a2.path)
      assert Attachments.list("conv-a") == []

      assert File.exists?(b1.path)
      assert Enum.map(Attachments.list("conv-b"), & &1.id) == [b1.id]
    end

    test "leaves no directory behind" do
      Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, dir} = Attachments.dir("conv-a")

      assert :ok = Attachments.purge("conv-a")
      refute File.exists?(dir)
    end

    test "is fine for a conversation that never staged anything" do
      assert :ok = Attachments.purge("conv-never")
    end
  end

  describe "sweep/1" do
    test "removes what is older than the TTL and keeps what is not" do
      {:ok, old} = Attachments.stage("conv-a", upload("old.png"), @png)
      {:ok, fresh} = Attachments.stage("conv-a", upload("fresh.png"), @jpeg)

      age(old.path, 3_600)

      assert {:ok, 1} = Attachments.sweep(ttl_seconds: 600)

      refute File.exists?(old.path)
      assert File.exists?(fresh.path)
      assert Enum.map(Attachments.list("conv-a"), & &1.id) == [fresh.id]
    end

    test "takes the sidecar of what it removes" do
      {:ok, old} = Attachments.stage("conv-a", upload("old.png"), @png)
      {:ok, dir} = Attachments.dir("conv-a")
      age(old.path, 3_600)

      assert {:ok, 1} = Attachments.sweep(ttl_seconds: 600)
      assert File.ls(dir) in [{:error, :enoent}, {:ok, []}]
    end

    test "sweeps across every conversation" do
      {:ok, a} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, b} = Attachments.stage("conv-b", upload("2.png"), @jpeg)
      age(a.path, 3_600)
      age(b.path, 3_600)

      assert {:ok, 2} = Attachments.sweep(ttl_seconds: 600)
      assert Attachments.list("conv-a") == []
      assert Attachments.list("conv-b") == []
    end

    test "respects the TTL exactly, and defaults to a day" do
      {:ok, att} = Attachments.stage("conv-a", upload("1.png"), @png)
      age(att.path, 3_600)

      # Younger than the TTL: untouched.
      assert {:ok, 0} = Attachments.sweep(ttl_seconds: 7_200)
      assert File.exists?(att.path)

      # And the default is generous enough that a same-day file survives.
      assert {:ok, 0} = Attachments.sweep()
      assert File.exists?(att.path)
    end

    test "collects an orphan sidecar left by a crash between the two writes" do
      {:ok, att} = Attachments.stage("conv-a", upload("1.png"), @png)
      {:ok, dir} = Attachments.dir("conv-a")
      meta = Path.join(dir, att.id <> ".meta.json")
      File.rm!(att.path)
      age(meta, 3_600)

      # It was never a listable attachment, so it is not counted — but it goes.
      assert {:ok, 0} = Attachments.sweep(ttl_seconds: 600)
      refute File.exists?(meta)
    end

    test "survives a staging root that does not exist yet" do
      assert {:ok, 0} = Attachments.sweep(ttl_seconds: 1)
    end

    defp age(path, seconds) do
      File.touch!(path, System.os_time(:second) - seconds)
    end
  end

  describe "where staging lives" do
    test "the default root is outside the workspace the agent browses", %{root: root} do
      Application.delete_env(:buster_claw, :attachments_root)
      prev_ws = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)

      on_exit(fn ->
        Application.put_env(:buster_claw, :attachments_root, Path.join(root, "staging"))

        case prev_ws do
          nil -> Application.delete_env(:buster_claw, :workspace_root)
          value -> Application.put_env(:buster_claw, :workspace_root, value)
        end
      end)

      workspace = BusterClaw.Library.Artifact.workspace_root()

      refute String.starts_with?(Attachments.root(), workspace <> "/")
      assert String.contains?(Attachments.root(), "buster-claw")
      assert String.ends_with?(Attachments.root(), "attachments")
    end
  end
end
