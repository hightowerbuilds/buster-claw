defmodule BusterClaw.Browser.CaptureTest do
  # async: false — toggles the global :browser_capture_timeout_ms and relies on the
  # singleton Capture GenServer started by the application.
  use ExUnit.Case, async: false

  alias BusterClaw.Browser.Capture

  test "request blocks until fulfilled and correlates by ref" do
    Capture.subscribe()
    task = Task.async(fn -> Capture.request() end)

    assert_receive {:capture, ref}, 1_000
    Capture.fulfill(ref, {:ok, %{path: "screenshots/2026-06-20/x.png", bytes: 4}})

    assert {:ok, %{path: "screenshots/2026-06-20/x.png", bytes: 4}} = Task.await(task)
  end

  test "a desktop-reported error is delivered to the caller" do
    Capture.subscribe()
    task = Task.async(fn -> Capture.request() end)

    assert_receive {:capture, ref}, 1_000
    Capture.fulfill(ref, {:error, {:capture_failed, "nil snapshot"}})

    assert {:error, {:capture_failed, "nil snapshot"}} = Task.await(task)
  end

  test "fulfilling an unknown ref is a harmless no-op" do
    assert :ok = Capture.fulfill("cap-does-not-exist", {:ok, %{}})
    assert Process.alive?(Process.whereis(Capture))
  end

  test "request times out cleanly when nothing answers" do
    prev = Application.get_env(:buster_claw, :browser_capture_timeout_ms)
    Application.put_env(:buster_claw, :browser_capture_timeout_ms, 50)
    on_exit(fn -> restore(:browser_capture_timeout_ms, prev) end)

    assert {:error, :capture_timeout} = Capture.request()
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
