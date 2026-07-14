defmodule BusterClaw.PagesTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Pages

  setup do
    root = Path.join(System.tmp_dir!(), "bc-pages-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "install! writes the bundled pages into <workspace>/pages/", %{root: root} do
    assert Pages.install!() == :ok

    manual = Path.join([root, "pages", "MANUAL.html"])
    assert File.read!(manual) =~ "<title>Buster Claw — Manual</title>"
  end

  test "install! relocates a legacy root-level MANUAL.html", %{root: root} do
    legacy = Path.join(root, "MANUAL.html")
    File.write!(legacy, "stale")

    Pages.install!()

    refute File.exists?(legacy)
    assert File.exists?(Path.join([root, "pages", "MANUAL.html"]))
  end

  test "install! removes retired bundled pages", %{root: root} do
    retired = Path.join([root, "pages", "financial-informant.html"])
    File.mkdir_p!(Path.dirname(retired))
    File.write!(retired, "<html><title>Financial Informant</title></html>")

    Pages.install!()

    refute File.exists?(retired)
    refute Enum.any?(Pages.list(), &(&1.file == "financial-informant.html"))
  end

  test "install! is idempotent — skips the rewrite when content matches", %{root: root} do
    Pages.install!()
    manual = Path.join([root, "pages", "MANUAL.html"])

    File.touch!(manual, {{2000, 1, 1}, {0, 0, 0}})
    Pages.install!()
    assert File.stat!(manual).mtime == {{2000, 1, 1}, {0, 0, 0}}
  end

  test "list returns agent pages (newest first) ahead of bundled ones", %{root: root} do
    Pages.install!()
    pages_dir = Path.join(root, "pages")

    older = Path.join(pages_dir, "older-report.html")
    newer = Path.join(pages_dir, "newer-report.html")
    File.write!(older, "<html><head><title>Older Report</title></head></html>")
    File.write!(newer, "<html><head><title> Newer\n  Report </title></head></html>")
    File.touch!(older, {{2026, 7, 1}, {0, 0, 0}})
    File.touch!(newer, {{2026, 7, 10}, {0, 0, 0}})
    # Non-HTML files are not pages.
    File.write!(Path.join(pages_dir, "notes.md"), "# notes")

    files = Enum.map(Pages.list(), & &1.file)

    assert files == [
             "newer-report.html",
             "older-report.html",
             "MANUAL.html"
           ]

    [newer_entry, older_entry | bundled] = Pages.list()
    # <title> wins, with whitespace collapsed.
    assert newer_entry.title == "Newer Report"
    assert older_entry.title == "Older Report"
    refute newer_entry.bundled?
    assert Enum.all?(bundled, & &1.bundled?)
  end

  test "list falls back to a humanized filename when there is no <title>", %{root: root} do
    Pages.install!()
    File.write!(Path.join([root, "pages", "solar-generator_v2.html"]), "<html></html>")

    entry = Enum.find(Pages.list(), &(&1.file == "solar-generator_v2.html"))
    assert entry.title == "Solar generator v2"
  end

  test "list is empty when the pages dir does not exist" do
    assert Pages.list() == []
  end
end
