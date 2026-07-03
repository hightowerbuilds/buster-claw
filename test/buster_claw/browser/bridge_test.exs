defmodule BusterClaw.Browser.BridgeTest do
  # async: false — toggles the global :browser_bridge_timeout_ms and relies on the
  # singleton Bridge GenServer started by the application.
  use ExUnit.Case, async: false

  alias BusterClaw.Browser.Bridge

  test "request broadcasts the action/payload and blocks until fulfilled" do
    Bridge.subscribe()
    task = Task.async(fn -> Bridge.request(:navigate, %{"url" => "https://example.com"}) end)

    assert_receive {:browser_command, ref, :navigate, %{"url" => "https://example.com"}}, 1_000
    Bridge.fulfill(ref, {:ok, %{url: nil, title: nil}})

    assert {:ok, %{url: nil, title: nil}} = Task.await(task)
  end

  test "a current request round-trips url + title" do
    Bridge.subscribe()
    task = Task.async(fn -> Bridge.request(:current) end)

    assert_receive {:browser_command, ref, :current, %{}}, 1_000
    Bridge.fulfill(ref, {:ok, %{url: "https://example.com/page", title: "Example"}})

    assert {:ok, %{url: "https://example.com/page", title: "Example"}} = Task.await(task)
  end

  test "a desktop-reported error is delivered to the caller" do
    Bridge.subscribe()
    task = Task.async(fn -> Bridge.request(:open_tab, %{"url" => "https://example.com"}) end)

    assert_receive {:browser_command, ref, :open_tab, _payload}, 1_000
    Bridge.fulfill(ref, {:error, {:browser_failed, "no browser surface open"}})

    assert {:error, {:browser_failed, "no browser surface open"}} = Task.await(task)
  end

  test "fulfilling an unknown ref is a harmless no-op" do
    assert :ok = Bridge.fulfill("cmd-does-not-exist", {:ok, %{}})
    assert Process.alive?(Process.whereis(Bridge))
  end

  test "request times out cleanly when nothing answers" do
    prev = Application.get_env(:buster_claw, :browser_bridge_timeout_ms)
    Application.put_env(:buster_claw, :browser_bridge_timeout_ms, 50)
    on_exit(fn -> restore(:browser_bridge_timeout_ms, prev) end)

    assert {:error, :browser_timeout} = Bridge.request(:current)
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
