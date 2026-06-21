defmodule BusterClawWeb.BrowserScreenshotControllerTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Browser.Capture

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    root = Path.join(System.tmp_dir!(), "bc-shot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      restore(:workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "POST /browser/screenshot stores the PNG and fulfils the capture", %{
    conn: conn,
    root: root
  } do
    Capture.subscribe()
    task = Task.async(fn -> Capture.request() end)
    assert_receive {:capture, ref}, 1_000

    conn =
      post(conn, ~p"/browser/screenshot", %{
        "ref" => ref,
        "url" => "https://example.com/page",
        "data" => Base.encode64(@png)
      })

    assert conn.status == 204

    assert {:ok, result} = Task.await(task)
    assert result.url == "https://example.com/page"
    assert result.bytes == byte_size(@png)
    assert result.path =~ ~r"^screenshots/\d{4}-\d{2}-\d{2}/cap-.+\.png$"
    assert File.read!(Path.join(root, result.path)) == @png
  end

  test "POST with an error fulfils the capture with that error", %{conn: conn} do
    Capture.subscribe()
    task = Task.async(fn -> Capture.request() end)
    assert_receive {:capture, ref}, 1_000

    conn = post(conn, ~p"/browser/screenshot", %{"ref" => ref, "error" => "no active tab"})
    assert conn.status == 204

    assert {:error, {:capture_failed, "no active tab"}} = Task.await(task)
  end

  test "POST with no ref is a 400", %{conn: conn} do
    conn = post(conn, ~p"/browser/screenshot", %{"data" => "x"})
    assert conn.status == 400
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
