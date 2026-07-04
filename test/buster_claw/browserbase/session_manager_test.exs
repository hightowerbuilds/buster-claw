defmodule BusterClaw.Browserbase.SessionManagerTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Browserbase.SessionManager

  # Fake client — no HTTP, no spend. Records releases by messaging the test pid
  # stashed in app env, so tests can assert reaping/close/terminate behavior.
  defmodule FakeClient do
    def create(_opts) do
      id = "sess-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, %{id: id, connect_url: "wss://connect/" <> id, status: "RUNNING"}}
    end

    def debug(id, _opts), do: {:ok, %{live_view_url: "https://live/" <> id}}

    def release(id, _opts) do
      case Application.get_env(:buster_claw, :test_bb_pid) do
        pid when is_pid(pid) -> send(pid, {:released, id})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule FailingClient do
    def create(_opts), do: {:error, :not_configured}
    def debug(_id, _opts), do: {:error, :not_configured}
    def release(_id, _opts), do: :ok
  end

  # Fake sidecar session driver — hands back a sidecar id, no HTTP.
  defmodule FakeSessionClient do
    def open(_connect_url, _opts) do
      {:ok, %{"id" => "sc_" <> Integer.to_string(System.unique_integer([:positive]))}}
    end

    def close(_sidecar_id, _opts), do: :ok
  end

  # Sidecar that refuses to take the session — exercises the no-leak path.
  defmodule FailingSessionClient do
    def open(_connect_url, _opts), do: {:error, :sidecar_unavailable}
    def close(_sidecar_id, _opts), do: :ok
  end

  # Client whose `create` parks until the test releases it, simulating a slow
  # network open. It announces the task pid so the test can decide when to let it
  # proceed — used to prove the manager loop is not blocked on an in-flight open.
  defmodule GatedClient do
    def create(opts) do
      gate = Keyword.fetch!(opts, :gate)
      send(gate, {:create_started, self()})

      receive do
        :go -> :ok
      after
        30_000 -> :ok
      end

      id = "sess-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, %{id: id, connect_url: "wss://connect/" <> id, status: "RUNNING"}}
    end

    def debug(id, _opts), do: {:ok, %{live_view_url: "https://live/" <> id}}

    def release(id, _opts) do
      case Application.get_env(:buster_claw, :test_bb_pid) do
        pid when is_pid(pid) -> send(pid, {:released, id})
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    Application.put_env(:buster_claw, :test_bb_pid, self())
    on_exit(fn -> Application.delete_env(:buster_claw, :test_bb_pid) end)
    :ok
  end

  defp start_manager(opts \\ []) do
    name = :"sm_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          client: FakeClient,
          session_client: FakeSessionClient,
          name: name,
          sweep_interval_ms: 10_000
        ],
        opts
      )

    start_supervised!({SessionManager, opts})
    [name: name]
  end

  test "open returns a handle with session id, live-view url, and connect url" do
    opts = start_manager()

    assert {:ok, handle} = SessionManager.open(opts)
    assert is_binary(handle.session_id)
    assert handle.connect_url =~ handle.session_id
    assert handle.live_view_url =~ handle.session_id
  end

  test "get returns metadata; touch defers a known session and errors on unknown" do
    opts = start_manager()
    {:ok, %{session_id: sid}} = SessionManager.open(opts)

    assert {:ok, meta} = SessionManager.get(sid, opts)
    assert meta.id == sid
    assert meta.connect_url =~ sid

    assert :ok = SessionManager.touch(sid, opts)
    assert {:error, :unknown_session} = SessionManager.touch("nope", opts)
    assert {:error, :unknown_session} = SessionManager.get("nope", opts)
  end

  test "close releases the cloud session and forgets it" do
    opts = start_manager()
    {:ok, %{session_id: sid}} = SessionManager.open(opts)

    assert [_one] = SessionManager.list(opts)
    assert :ok = SessionManager.close(sid, opts)
    assert_receive {:released, ^sid}
    assert [] = SessionManager.list(opts)
  end

  test "enforces max concurrency" do
    opts = start_manager(max_concurrent: 2)

    assert {:ok, _} = SessionManager.open(opts)
    assert {:ok, _} = SessionManager.open(opts)
    assert {:error, :max_sessions} = SessionManager.open(opts)
  end

  test "reaps idle sessions on the sweep" do
    opts = start_manager(idle_timeout_ms: 20, sweep_interval_ms: 10)
    {:ok, %{session_id: sid}} = SessionManager.open(opts)

    assert_receive {:released, ^sid}, 1_000
    assert [] = SessionManager.list(opts)
  end

  test "reaps over-age sessions even when freshly touched" do
    opts = start_manager(idle_timeout_ms: 60_000, max_lifetime_ms: 20, sweep_interval_ms: 10)
    {:ok, %{session_id: sid}} = SessionManager.open(opts)
    :ok = SessionManager.touch(sid, opts)

    assert_receive {:released, ^sid}, 1_000
  end

  test "releases every held session on graceful shutdown" do
    opts = start_manager()
    {:ok, %{session_id: a}} = SessionManager.open(opts)
    {:ok, %{session_id: b}} = SessionManager.open(opts)

    :ok = stop_supervised(SessionManager)

    assert_receive {:released, ^a}
    assert_receive {:released, ^b}
  end

  test "propagates a client create failure" do
    opts = start_manager(client: FailingClient)
    assert {:error, :not_configured} = SessionManager.open(opts)
  end

  test "releases the paid session (no leak) when the sidecar refuses to drive it" do
    opts = start_manager(session_client: FailingSessionClient)

    assert {:error, {:sidecar_open_failed, :sidecar_unavailable}} = SessionManager.open(opts)
    # the Browserbase session created moments earlier was released, not orphaned
    assert_receive {:released, _id}
    assert [] = SessionManager.list(opts)
  end

  test "a slow open never blocks touch on other sessions (no head-of-line blocking)" do
    opts = start_manager(client: GatedClient, client_opts: [gate: self()])

    # First open — let it proceed immediately so we have a live session to touch.
    first = Task.async(fn -> SessionManager.open(opts) end)
    assert_receive {:create_started, t1}, 1_000
    send(t1, :go)
    assert {:ok, %{session_id: sid}} = Task.await(first)

    # Second open — leave its network I/O parked in flight.
    second = Task.async(fn -> SessionManager.open(opts) end)
    assert_receive {:create_started, t2}, 1_000

    # With the blocking I/O off the loop, touch of the first session still
    # returns promptly. (Under the old serialized do_open it would sit behind the
    # parked open and blow the 5s call timeout.)
    assert :ok = SessionManager.touch(sid, opts)

    # Release the parked open so nothing leaks/hangs on teardown.
    send(t2, :go)
    assert {:ok, _} = Task.await(second)
  end

  test "an in-flight open counts toward max concurrency (no cap breach)" do
    opts = start_manager(client: GatedClient, client_opts: [gate: self()], max_concurrent: 1)

    parked = Task.async(fn -> SessionManager.open(opts) end)
    assert_receive {:create_started, gate_pid}, 1_000

    # While the first open is still creating, a second open must be rejected —
    # the reserved slot counts, so a slow open can't overshoot the paid-session cap.
    assert {:error, :max_sessions} = SessionManager.open(opts)

    send(gate_pid, :go)
    assert {:ok, _} = Task.await(parked)
  end
end
