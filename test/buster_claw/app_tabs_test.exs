defmodule BusterClaw.AppTabsTest do
  use ExUnit.Case, async: true
  alias BusterClaw.AppTabs

  setup do
    %{server: start_supervised!({AppTabs, name: nil})}
  end

  defp request(server, action, timeout \\ 1_000) do
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(parent, {:result, AppTabs.request(action, %{}, server: server, timeout: timeout)})
       end}
    )
  end

  test "an absent UI fails immediately without queuing a later mutation", %{server: server} do
    assert {:error, :app_tabs_unavailable} = AppTabs.request(:join, %{}, server: server)
    AppTabs.register(server)
    refute_receive {:app_tabs, _}
  end

  test "only the chosen shell can acknowledge a result", %{server: server} do
    AppTabs.register(server)
    request(server, :join)
    assert_receive {:app_tabs, %{ref: ref, action: :join}}
    parent = self()

    start_supervised!(
      {Task, fn -> send(parent, {:forged, AppTabs.fulfill(ref, {:ok, %{}}, server)}) end},
      id: :other
    )

    assert_receive {:forged, false}
    refute_receive {:result, _}
    assert AppTabs.fulfill(ref, {:ok, %{changed: true}}, server)
    assert_receive {:result, {:ok, %{changed: true}}}
    refute AppTabs.fulfill(ref, {:ok, %{}}, server)
  end

  test "expired commands cannot be acknowledged later", %{server: server} do
    AppTabs.register(server)
    request(server, :separate, 10)
    assert_receive {:app_tabs, %{ref: ref}}
    assert_receive {:result, {:error, :app_tabs_timeout}}
    refute AppTabs.fulfill(ref, {:ok, %{}}, server)
  end

  test "a disconnected shell releases its pending caller", %{server: server} do
    parent = self()

    client =
      start_supervised!(
        {Task,
         fn ->
           AppTabs.register(server)
           send(parent, :ready)

           receive do
             {:app_tabs, _request} -> send(parent, :received)
           end
         end},
        id: :client
      )

    monitor = Process.monitor(client)
    assert_receive :ready
    request(server, :join)
    assert_receive :received
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
    assert_receive {:result, {:error, :app_tabs_disconnected}}
    assert {:error, :app_tabs_unavailable} = AppTabs.request(:list, %{}, server: server)
  end
end
