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
end
