defmodule BusterClaw.FileManagerTest do
  use ExUnit.Case, async: true

  alias BusterClaw.FileManager

  setup do
    base =
      Path.join(System.tmp_dir!(), "buster-claw-fm-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "alpha"))
    File.mkdir_p!(Path.join(base, "beta"))
    File.write!(Path.join(base, "notes.md"), "# hello\n")

    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "list returns dirs first then files, alpha-sorted", %{base: base} do
    {:ok, entries} = FileManager.list(base, base)
    assert Enum.map(entries, & &1.name) == ["alpha", "beta", "notes.md"]
    assert Enum.map(entries, & &1.type) == [:dir, :dir, :file]
  end

  test "read_file returns text and rejects binary", %{base: base} do
    assert {:ok, "# hello\n"} = FileManager.read_file(Path.join(base, "notes.md"), base)

    File.write!(Path.join(base, "bin"), <<0, 1, 2, 255>>)
    assert {:error, :binary} = FileManager.read_file(Path.join(base, "bin"), base)
  end

  test "create_dir and create_file", %{base: base} do
    assert {:ok, dir} = FileManager.create_dir(base, "gamma", base)
    assert File.dir?(dir)

    assert {:ok, file} = FileManager.create_file(base, "todo.txt", base)
    assert File.regular?(file)

    assert {:error, :already_exists} = FileManager.create_dir(base, "alpha", base)
  end

  test "rename and move", %{base: base} do
    assert {:ok, renamed} = FileManager.rename(Path.join(base, "notes.md"), "renamed.md", base)
    assert Path.basename(renamed) == "renamed.md"
    refute File.exists?(Path.join(base, "notes.md"))

    assert {:ok, moved} = FileManager.move(renamed, Path.join(base, "alpha"), base)
    assert moved == Path.join([base, "alpha", "renamed.md"])
    assert File.exists?(moved)
  end

  test "delete removes entries but refuses the base itself", %{base: base} do
    assert :ok = FileManager.delete(Path.join(base, "beta"), base)
    refute File.exists?(Path.join(base, "beta"))
    assert {:error, :cannot_delete_base} = FileManager.delete(base, base)
  end

  test "rejects operations outside the base", %{base: base} do
    assert {:error, :outside_base} = FileManager.list(Path.join(base, ".."), base)
    assert {:error, :outside_base} = FileManager.read_file("/etc/hosts", base)
    assert {:error, :invalid_name} = FileManager.create_dir(base, "../escape", base)
    assert {:error, :invalid_name} = FileManager.rename(Path.join(base, "alpha"), "../x", base)
  end

  test "rejects a symlink inside the base that points outside it", %{base: base} do
    outside =
      Path.join(System.tmp_dir!(), "buster-claw-fm-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "top secret\n")
    on_exit(fn -> File.rm_rf(outside) end)

    link = Path.join(base, "escape")
    :ok = File.ln_s(outside, link)

    # Lexically `base/escape/...` looks contained, but it resolves outside `base`.
    refute FileManager.within?(Path.join(link, "secret.txt"), base)
    assert {:error, :outside_base} = FileManager.list(link, base)
    assert {:error, :outside_base} = FileManager.read_file(Path.join(link, "secret.txt"), base)
  end

  test "image? recognizes image extensions, case-insensitively" do
    assert FileManager.image?("/x/photo.png")
    assert FileManager.image?("/x/PHOTO.JPG")
    assert FileManager.image?("shot.webp")
    assert FileManager.image?("icon.svg")
    refute FileManager.image?("/x/notes.md")
    refute FileManager.image?("/x/archive.zip")
  end

  test "image_content_type maps by extension" do
    assert FileManager.image_content_type("a.png") == "image/png"
    assert FileManager.image_content_type("a.JPEG") == "image/jpeg"
    assert FileManager.image_content_type("a.svg") == "image/svg+xml"
    assert FileManager.image_content_type("a.bin") == "application/octet-stream"
  end

  test "servable_file resolves a regular file inside base; rejects dirs and escapes",
       %{base: base} do
    File.write!(Path.join(base, "pic.png"), "not really a png")
    assert {:ok, abs} = FileManager.servable_file(Path.join(base, "pic.png"), base)
    assert abs == Path.expand(Path.join(base, "pic.png"))

    assert {:error, :not_a_file} = FileManager.servable_file(Path.join(base, "alpha"), base)
    assert {:error, :outside_base} = FileManager.servable_file("/etc/hosts", base)
  end

  test "import_file copies an external file in, deduping name collisions", %{base: base} do
    src = Path.join(System.tmp_dir!(), "fm-src-#{System.unique_integer([:positive])}.txt")
    File.write!(src, "payload")
    on_exit(fn -> File.rm_rf(src) end)

    assert {:ok, first} = FileManager.import_file(src, base, "dropped.txt", base)
    assert Path.basename(first) == "dropped.txt"
    assert File.read!(first) == "payload"

    # A second import of the same name doesn't overwrite — it suffixes.
    assert {:ok, second} = FileManager.import_file(src, base, "dropped.txt", base)
    assert Path.basename(second) == "dropped (1).txt"
    assert File.exists?(first) and File.exists?(second)
  end

  test "import_file rejects a destination outside the base and a non-directory dest",
       %{base: base} do
    src = Path.join(System.tmp_dir!(), "fm-src-#{System.unique_integer([:positive])}.txt")
    File.write!(src, "x")
    on_exit(fn -> File.rm_rf(src) end)

    assert {:error, :outside_base} = FileManager.import_file(src, "/tmp", "a.txt", base)

    assert {:error, :not_a_directory} =
             FileManager.import_file(src, Path.join(base, "notes.md"), "a.txt", base)

    assert {:error, :invalid_name} = FileManager.import_file(src, base, "../evil.txt", base)
  end
end
