defmodule BusterClaw.Commands.WebCapturePageTest do
  # async: false — shared DB sandbox (the command runs inside a Task), a tmp
  # :library_root swap, and the singleton Bridge/Capture GenServers.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Browser.{Bridge, Capture}
  alias BusterClaw.{Commands, Library}

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-capture-page-test-#{System.unique_integer([:positive])}"
      )

    prev_lib = Application.get_env(:buster_claw, :library_root)
    prev_ws = Application.get_env(:buster_claw, :workspace_root)

    Application.put_env(:buster_claw, :library_root, Path.join(base, "library"))
    Application.delete_env(:buster_claw, :workspace_root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, prev_lib)
      if prev_ws, do: Application.put_env(:buster_claw, :workspace_root, prev_ws)
      File.rm_rf(base)
    end)

    :ok
  end

  defp page_payload do
    %{
      "url" => "https://app.example.com/dashboard",
      "title" => "Dashboard",
      "text" => "Welcome back, Luke",
      "links" => [%{"label" => "Settings", "url" => "https://app.example.com/settings"}]
    }
  end

  test "captures the page into a Library artifact plus a screenshot" do
    Bridge.subscribe()
    Capture.subscribe()

    task = Task.async(fn -> Commands.browser_capture_page() end)

    assert_receive {:browser_command, ref, :read, _payload}, 1_000
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(page_payload())}})

    assert_receive {:capture, cap_ref}, 1_000

    Capture.fulfill(
      cap_ref,
      {:ok, %{path: "screenshots/2026-07-03/#{cap_ref}.png", bytes: 4}}
    )

    assert {:ok, result} = Task.await(task)

    assert result.url == "https://app.example.com/dashboard"
    assert result.title == "Dashboard"
    assert result.screenshot == "screenshots/2026-07-03/#{cap_ref}.png"

    # The markdown artifact exists on disk and carries the captured content.
    assert File.exists?(result.absolute_path)
    content = File.read!(result.absolute_path)
    assert content =~ "# Dashboard"
    assert content =~ "Welcome back, Luke"
    assert content =~ "- Source: https://app.example.com/dashboard"
    assert content =~ "- Captured: "
    assert content =~ "[Settings](https://app.example.com/settings)"

    # And the Library document row points at it.
    document = Library.get_document!(result.document_id)
    assert document.artifact_path == result.path
    assert document.source_url == "https://app.example.com/dashboard"
    assert "browser-capture" in document.tags["items"]
  end

  test "a failed screenshot still yields the text artifact (screenshot: nil)" do
    Bridge.subscribe()
    Capture.subscribe()

    task = Task.async(fn -> Commands.browser_capture_page(%{"title" => "My capture"}) end)

    assert_receive {:browser_command, ref, :read, _payload}, 1_000
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(page_payload())}})

    assert_receive {:capture, cap_ref}, 1_000
    Capture.fulfill(cap_ref, {:error, {:capture_failed, "nil snapshot"}})

    assert {:ok, result} = Task.await(task)

    assert result.screenshot == nil
    # The "title" arg overrides the page title.
    assert result.title == "My capture"
    assert File.exists?(result.absolute_path)
    assert File.read!(result.absolute_path) =~ "Welcome back, Luke"
  end

  test "a read failure propagates and writes nothing" do
    Bridge.subscribe()
    Capture.subscribe()

    task = Task.async(fn -> Commands.browser_capture_page() end)

    assert_receive {:browser_command, ref, :read, _payload}, 1_000
    Bridge.fulfill(ref, {:ok, %{data: "not json"}})

    assert {:error, :bad_page_payload} = Task.await(task)

    # No screenshot was even attempted, and no artifact/document was written.
    refute_receive {:capture, _cap_ref}, 100
    assert Library.list_documents() == []
    refute File.exists?(Path.join(Library.library_root(), "raw"))
  end
end
