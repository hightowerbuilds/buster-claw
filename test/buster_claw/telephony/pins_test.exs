defmodule BusterClaw.Telephony.PinsTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Telephony.Pins

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp opts, do: [req_options: [plug: {Req.Test, __MODULE__}]]

  # Capture the JSON body of the upsert POST into the test process so we can
  # assert exactly what left the Mac (hash, salt, failed_attempts) — and, just as
  # importantly, what did NOT (any plaintext pin).
  defp stub_capture do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: %{}, else: Jason.decode!(body)
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        test_pid,
        {:pins_request, conn.method, conn.request_path, decoded, conn.query_params,
         Plug.Conn.get_req_header(conn, "prefer")}
      )

      Plug.Conn.send_resp(conn, 204, "")
    end)
  end

  describe "set_pin/3" do
    test "hashes salt<>pin to lowercase-hex sha256 and never sends the plaintext" do
      stub_capture()
      # A fixed salt makes the stored hash deterministic and independently checkable.
      salt = "0011223344556677889900aabbccddee"
      pin = "4815"
      expected = Base.encode16(:crypto.hash(:sha256, salt <> pin), case: :lower)

      assert {:ok, "+15035551234"} =
               Pins.set_pin("(503) 555-1234", pin, Keyword.merge(opts(), salt: salt))

      assert_received {:pins_request, "POST", "/rest/v1/phone_pins", body, _params, prefer}

      assert body["number"] == "+15035551234"
      assert body["pin_hash"] == expected
      assert body["salt"] == salt
      assert body["failed_attempts"] == 0
      # The plaintext PIN must never cross the wire under any key.
      refute Map.has_key?(body, "pin")
      refute body |> Map.values() |> Enum.any?(&(&1 == pin))
      # Upsert on the primary key.
      assert prefer == ["resolution=merge-duplicates,return=minimal"]
    end

    test "hash_pin/2 matches the Deno contract expression exactly" do
      salt = "abc123"
      pin = "9090"

      assert Pins.hash_pin(salt, pin) ==
               Base.encode16(:crypto.hash(:sha256, salt <> pin), case: :lower)
    end

    test "an unnormalizable number is rejected before any wire call" do
      # No stub installed: a request here would raise, proving we never reach it.
      assert {:error, :invalid_number} = Pins.set_pin("nope", "4815", opts())
    end

    test "a too-short PIN is rejected" do
      assert {:error, :invalid_pin} = Pins.set_pin("+15035551234", "12", opts())
    end

    test "a non-digit PIN is rejected" do
      assert {:error, :invalid_pin} = Pins.set_pin("+15035551234", "48a5", opts())
    end

    test "a too-long PIN is rejected" do
      assert {:error, :invalid_pin} = Pins.set_pin("+15035551234", "123456789012", opts())
    end
  end

  describe "remove_pin/2" do
    test "deletes by E.164 and is idempotent" do
      stub_capture()

      assert :ok = Pins.remove_pin("844-687-8016", opts())

      assert_received {:pins_request, "DELETE", "/rest/v1/phone_pins", _body, params, _prefer}
      assert params["number"] == "eq.+18446878016"
    end

    test "an unnormalizable number is rejected" do
      assert {:error, :invalid_number} = Pins.remove_pin("nope", opts())
    end
  end

  describe "list_pins/1" do
    test "selects only non-credential columns — never pin_hash or salt" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:select, conn.query_params["select"]})

        Req.Test.json(conn, [
          %{"number" => "+15035551234", "failed_attempts" => 0, "last_verified_at" => nil}
        ])
      end)

      assert {:ok, [row]} = Pins.list_pins(opts())
      assert row["number"] == "+15035551234"
      refute Map.has_key?(row, "pin_hash")
      refute Map.has_key?(row, "salt")

      assert_received {:select, select}
      refute select =~ "pin_hash"
      refute select =~ "salt"
    end
  end

  describe "not configured (fail closed)" do
    setup do
      prev_url = Application.get_env(:buster_claw, :telephony_relay_url)
      prev_key = Application.get_env(:buster_claw, :telephony_relay_key)
      Application.delete_env(:buster_claw, :telephony_relay_url)
      Application.delete_env(:buster_claw, :telephony_relay_key)

      on_exit(fn ->
        Application.put_env(:buster_claw, :telephony_relay_url, prev_url)
        Application.put_env(:buster_claw, :telephony_relay_key, prev_key)
      end)

      :ok
    end

    test "every function returns :not_configured rather than crashing" do
      assert {:error, :not_configured} = Pins.set_pin("+15035551234", "4815", opts())
      assert {:error, :not_configured} = Pins.remove_pin("+15035551234", opts())
      assert {:error, :not_configured} = Pins.list_pins(opts())
    end
  end
end
