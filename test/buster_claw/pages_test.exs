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
    finance = Path.join([root, "pages", "financial-informant.html"])

    assert File.read!(manual) =~ "<title>Buster Claw — Manual</title>"
    assert File.read!(finance) =~ "<title>Financial Informant</title>"
    # The page is live: it fetches from the loopback finance JSON surface.
    assert File.read!(finance) =~ "/finance/api/lookup"
  end

  test "install! relocates a legacy root-level MANUAL.html", %{root: root} do
    legacy = Path.join(root, "MANUAL.html")
    File.write!(legacy, "stale")

    Pages.install!()

    refute File.exists?(legacy)
    assert File.exists?(Path.join([root, "pages", "MANUAL.html"]))
  end

  test "install! is idempotent — skips the rewrite when content matches", %{root: root} do
    Pages.install!()
    manual = Path.join([root, "pages", "MANUAL.html"])

    File.touch!(manual, {{2000, 1, 1}, {0, 0, 0}})
    Pages.install!()
    assert File.stat!(manual).mtime == {{2000, 1, 1}, {0, 0, 0}}
  end
end
