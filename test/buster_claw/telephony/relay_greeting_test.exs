defmodule BusterClaw.Telephony.RelayGreetingTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Telephony.Relay

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp opts, do: [req_options: [plug: {Req.Test, __MODULE__}]]

  defp expect_request(method, status) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == method
      assert conn.request_path == "/storage/v1/object/recordings/greeting/greeting.wav"
      assert Plug.Conn.get_req_header(conn, "apikey") == ["test-service-role-key"]
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  test "checks existing published audio without replacing or deleting it" do
    expect_request("HEAD", 200)
    assert Relay.greeting_status(opts()) == {:ok, :published}
  end

  test "only missing audio establishes the default greeting" do
    expect_request("HEAD", 404)
    assert Relay.greeting_status(opts()) == {:ok, :default}
  end

  test "authorization, service and transport failures remain unavailable" do
    for status <- [401, 403, 500, 503] do
      expect_request("HEAD", status)
      assert {:error, {:storage_status, ^status, _}} = Relay.greeting_status(opts())
    end

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, {:storage_request_failed, _}} = Relay.greeting_status(opts())
  end

  test "reset deletes only the greeting and accepts an already absent recording" do
    expect_request("DELETE", 200)
    assert Relay.delete_greeting(opts()) == :ok
    expect_request("DELETE", 404)
    assert Relay.delete_greeting(opts()) == {:ok, :gone}
  end

  test "a failed reset never reports success" do
    expect_request("DELETE", 403)
    assert {:error, {:storage_status, 403, _}} = Relay.delete_greeting(opts())
  end

  test "missing relay credentials cause no request" do
    previous = Application.fetch_env!(:buster_claw, :telephony_relay_key)
    Application.delete_env(:buster_claw, :telephony_relay_key)
    on_exit(fn -> Application.put_env(:buster_claw, :telephony_relay_key, previous) end)

    assert Relay.greeting_status(opts()) == {:error, :not_configured}
    assert Relay.delete_greeting(opts()) == {:error, :not_configured}
  end
end
