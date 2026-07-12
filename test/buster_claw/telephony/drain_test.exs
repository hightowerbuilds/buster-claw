defmodule BusterClaw.Telephony.DrainTest do
  use BusterClaw.DataCase

  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Drain

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, tmp_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :library_root, previous)
      else
        Application.delete_env(:buster_claw, :library_root)
      end
    end)

    Req.Test.verify_on_exit!()
    :ok
  end

  defp state, do: %{transcript_grace_ms: 180_000, req_options: [plug: {Req.Test, __MODULE__}]}

  defp relay_row(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "9b2e6c1a-0000-4000-8000-000000000001",
        "direction" => "inbound",
        "kind" => "voicemail",
        "from_number" => "+15035551234",
        "to_number" => "+18446878016",
        "body" => nil,
        "duration_seconds" => 12,
        "recording_path" => "2026-07-12/voicemail-RE123.mp3",
        "transcript" => "Hey, call me back.",
        "twilio_sid" => "RE123",
        "synced" => false,
        "created_at" => "2026-07-12T10:00:00+00:00"
      },
      overrides
    )
  end

  # One stub routes all three relay calls by method + path; storage behavior
  # and PATCH tracking are parameterized through the test process.
  defp stub_relay(rows, opts \\ []) do
    test_pid = self()
    storage = Keyword.get(opts, :storage, {:ok, "mp3-bytes"})

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/rest/v1/telephony_events"} ->
          Req.Test.json(conn, rows)

        {"PATCH", "/rest/v1/telephony_events"} ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:acked, conn.query_params["id"]})
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/storage/v1/object/recordings/" <> _path} ->
          case storage do
            {:ok, bytes} ->
              conn
              |> Plug.Conn.put_resp_content_type("audio/mpeg")
              |> Plug.Conn.send_resp(200, bytes)

            {:error, status} ->
              Plug.Conn.send_resp(conn, status, "")
          end
      end
    end)
  end

  test "drains a voicemail: audio to the Library, event to SQLite, remote acked",
       %{tmp_dir: tmp_dir} do
    stub_relay([relay_row()])

    assert :ok = Drain.drain(state())

    assert [event] = Telephony.list_events()
    assert event.kind == "voicemail"
    assert event.from_number == "+15035551234"
    assert event.transcript == "Hey, call me back."
    assert event.twilio_sid == "RE123"
    assert event.recording_path == "phone/recordings/2026-07-12/voicemail-RE123.mp3"
    assert File.read!(Path.join(tmp_dir, event.recording_path)) == "mp3-bytes"

    assert_received {:acked, "eq.9b2e6c1a-0000-4000-8000-000000000001"}
  end

  test "a re-drained row (already local) is acked without a duplicate" do
    stub_relay([relay_row()])

    assert :ok = Drain.drain(state())
    assert_received {:acked, _}

    # Crash-between-persist-and-ack: the same row comes back next tick.
    stub_relay([relay_row()])
    assert :ok = Drain.drain(state())

    assert length(Telephony.list_events()) == 1
    assert_received {:acked, _}
  end

  test "a young voicemail without a transcript waits for the grace window" do
    young =
      relay_row(%{
        "transcript" => nil,
        "created_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    stub_relay([young])

    assert :ok = Drain.drain(state())
    assert Telephony.list_events() == []
    refute_received {:acked, _}
  end

  test "an old voicemail without a transcript drains anyway" do
    stub_relay([relay_row(%{"transcript" => nil})])

    assert :ok = Drain.drain(state())

    assert [event] = Telephony.list_events()
    assert event.transcript == nil
    assert_received {:acked, _}
  end

  test "a missing recording (404) drains without audio rather than blocking" do
    stub_relay([relay_row()], storage: {:error, 404})

    assert :ok = Drain.drain(state())

    assert [event] = Telephony.list_events()
    assert event.recording_path == nil
    assert event.metadata["recording_missing"] == true
    assert_received {:acked, _}
  end

  test "a transient storage failure leaves the row queued for retry" do
    stub_relay([relay_row()], storage: {:error, 500})

    assert :ok = Drain.drain(state())

    assert Telephony.list_events() == []
    refute_received {:acked, _}
  end

  test "a traversal recording_path from the relay is refused" do
    stub_relay([relay_row(%{"recording_path" => "../../etc/passwd.mp3"})])

    assert :ok = Drain.drain(state())

    assert Telephony.list_events() == []
    refute_received {:acked, _}
  end

  test "a relay read failure is survived" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    assert :ok = Drain.drain(state())
    assert Telephony.list_events() == []
  end
end
