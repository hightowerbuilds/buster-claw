defmodule BusterClaw.Messages.ConnectionTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Messages
  alias BusterClaw.Messages.Connection

  setup do
    root = Path.join(System.tmp_dir!(), "messages-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp fixture(root, body) do
    # A filename containing shell metacharacters must still be one argv element.
    path = Path.join(root, "adapter ; literal")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  defp connect(root, body, opts \\ []) do
    binary = fixture(root, body)
    # Match the real connection's budget: starting a shell can exceed one second
    # while the full suite launches other adapters. Timeout behavior is tested
    # separately with an explicit short deadline.
    start_supervised!({Connection, Keyword.merge([binary: binary, timeout: 5_000], opts)})
  end

  defp response(ready \\ true) do
    Jason.encode!(%{
      jsonrpc: "2.0",
      id: 1,
      result: %{
        version: "0.15.6",
        protocol_version: 1,
        database: %{ready: ready},
        methods: ~w(chats.list messages.history watch.subscribe)
      }
    })
  end

  defp reply_script(response) do
    "IFS= read -r request\nprintf '%s\\n' '#{response}'\nwhile IFS= read -r request; do :; done\n"
  end

  test "starts lazily and sends only a status request", %{root: root} do
    body = """
    IFS= read -r request
    case "$request" in
      *'"method":"status"'*) printf '%s\\n' '#{response()}' ;;
      *) exit 4 ;;
    esac
    while IFS= read -r request; do :; done
    """

    pid = connect(root, body)
    assert :sys.get_state(pid).port == nil
    assert {:ok, %{state: :read_ready, send_ready: false}} = Connection.status(pid)
  end

  test "accepts a JSON response fragmented across writes", %{root: root} do
    {left, right} = String.split_at(response(), 40)

    pid =
      connect(root, """
      IFS= read -r request
      printf '%s' '#{left}'
      printf '%s\\n' '#{right}'
      while IFS= read -r request; do :; done
      """)

    assert {:ok, %{read_ready: true}} = Connection.status(pid)
  end

  test "correlates out-of-order responses and recovers database readiness", %{root: root} do
    second = String.replace(response(), "\"id\":1", "\"id\":2")

    pid =
      connect(root, """
      IFS= read -r first
      IFS= read -r second
      printf '%s\\n%s\\n' '#{second}' '#{response(false)}'
      while IFS= read -r request; do :; done
      """)

    first = :gen_server.send_request(pid, :status)
    second = :gen_server.send_request(pid, :status)

    assert {:reply, {:ok, %{state: :database_unavailable}}} =
             :gen_server.receive_response(first, 6_000)

    assert {:reply, {:ok, %{state: :read_ready}}} = :gen_server.receive_response(second, 6_000)
  end

  test "malformed output fails requests, closes the port and backs off", %{root: root} do
    pid = connect(root, reply_script("not json"))
    assert {:error, :invalid_response} = Connection.status(pid)
    assert :sys.get_state(pid).port == nil
    assert {:error, :backoff} = Connection.status(pid)
  end

  test "unknown request IDs cannot be mistaken for a successful probe", %{root: root} do
    body = reply_script(String.replace(response(), "\"id\":1", "\"id\":99"))
    pid = connect(root, body)
    assert {:error, :unexpected_response} = Connection.status(pid)
  end

  test "adapter errors are redacted", %{root: root} do
    error =
      Jason.encode!(%{jsonrpc: "2.0", id: 1, error: %{code: -32_002, message: "secret address"}})

    pid = connect(root, reply_script(error))
    assert {:error, :adapter_error} = Connection.status(pid)
  end

  test "oversized unterminated response is bounded", %{root: root} do
    pid = connect(root, reply_script(String.duplicate("x", 65_537)))
    assert {:error, :response_too_large} = Connection.status(pid)
  end

  test "a stalled helper times out and frees the connection", %{root: root} do
    pid = connect(root, "while IFS= read -r request; do :; done\n", timeout: 25)
    assert {:error, :timeout} = Connection.status(pid)
    assert :sys.get_state(pid).pending == %{}
    assert :sys.get_state(pid).port == nil
  end

  test "pending requests are bounded", %{root: root} do
    pid = connect(root, "while IFS= read -r request; do :; done\n")
    requests = for _ <- 1..8, do: :gen_server.send_request(pid, :status)
    assert {:error, :busy} = Connection.status(pid)
    GenServer.stop(pid)

    for request <- requests do
      assert {:reply, {:error, :connection_closed}} = :gen_server.receive_response(request, 1_000)
    end
  end

  test "child exit fails the request without crashing its owner", %{root: root} do
    pid = connect(root, "IFS= read -r request\nexit 7\n")
    assert {:error, :adapter_exited} = Connection.status(pid)
    assert :sys.get_state(pid).port == nil
  end

  test "missing explicit binary never falls back to an installed helper" do
    assert {:error, :not_installed} = Messages.probe(binary: "/missing/messages-adapter")
  end

  test "reconnects on a later request after child failure", %{root: root} do
    pid =
      connect(
        root,
        """
        IFS= read -r request
        if [ ! -f "$0.started" ]; then
          : > "$0.started"
          exit 7
        fi
        printf '%s\\n' '#{String.replace(response(), "\"id\":1", "\"id\":2")}'
        while IFS= read -r request; do :; done
        """,
        retry_ms: 0
      )

    assert {:error, :adapter_exited} = Connection.status(pid)
    assert {:ok, %{read_ready: true}} = Connection.status(pid)
  end

  test "stopping the supervised connection closes its owned port", %{root: root} do
    pid = connect(root, reply_script(response()))
    assert {:ok, _} = Connection.status(pid)
    port = :sys.get_state(pid).port
    monitor = :erlang.monitor(:port, port)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^monitor, :port, ^port, :normal}
  end
end
