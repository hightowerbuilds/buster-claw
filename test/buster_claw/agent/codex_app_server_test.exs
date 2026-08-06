defmodule BusterClaw.Agent.CodexAppServerTest do
  @moduledoc """
  The JSON-RPC connection, driven against a scripted stand-in for
  `codex app-server`.

  The stand-in is a real Port running a tiny script that speaks the shapes the
  Phase 0 probe captured, so the framing, request correlation, and notification
  routing are exercised for real rather than mocked away. What it must NOT do is
  invent shapes: every response and notification below is copied from
  `tmp/probes/codex-appserver-steer.jsonl`.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.CodexAppServer
  alias BusterClaw.Agent.StreamEvent

  @thread "019fd043-9450-7d13-80b7-7cd9729671f8"
  @turn "019fd043-9499-7a71-8e4d-7cea495099ac"

  # A stand-in app-server: reads one JSON-RPC request per line and answers it,
  # emitting notifications where the real thing would. Written in `jq`-free
  # plain Perl so it needs nothing installed beyond what `AgentRunner` already
  # assumes.
  defp fake_server_script do
    """
    $| = 1;
    while (my $line = <STDIN>) {
      my ($id) = $line =~ /"id":(\\d+)/;
      if ($line =~ /"method":"initialize"/) {
        print "{\\"id\\":$id,\\"result\\":{\\"userAgent\\":\\"fake\\"}}\\n";
      } elsif ($line =~ /"method":"thread\\/start"/) {
        print "{\\"id\\":$id,\\"result\\":{\\"threadId\\":\\"#{@thread}\\"}}\\n";
        print "{\\"method\\":\\"thread\\/started\\",\\"params\\":{\\"thread\\":{\\"id\\":\\"#{@thread}\\"}}}\\n";
      } elsif ($line =~ /"method":"thread\\/resume"/) {
        print "{\\"id\\":$id,\\"result\\":{\\"threadId\\":\\"#{@thread}\\"}}\\n";
      } elsif ($line =~ /"method":"turn\\/start"/) {
        print "{\\"id\\":$id,\\"result\\":{\\"turn\\":{\\"id\\":\\"#{@turn}\\",\\"status\\":\\"inProgress\\"}}}\\n";
        print "{\\"method\\":\\"item\\/completed\\",\\"params\\":{\\"threadId\\":\\"#{@thread}\\",\\"turnId\\":\\"#{@turn}\\",\\"item\\":{\\"type\\":\\"agentMessage\\",\\"text\\":\\"working on it\\"}}}\\n";
      } elsif ($line =~ /"expectedTurnId":"#{@turn}"/) {
        print "{\\"id\\":$id,\\"result\\":{\\"turnId\\":\\"#{@turn}\\"}}\\n";
      } elsif ($line =~ /"method":"turn\\/steer"/) {
        print "{\\"id\\":$id,\\"error\\":{\\"code\\":-32600,\\"message\\":\\"no active turn to steer\\"}}\\n";
      } elsif ($line =~ /"method":"turn\\/interrupt"/) {
        print "{\\"id\\":$id,\\"result\\":{}}\\n";
      }
    }
    """
  end

  defp start_server do
    script = fake_server_script()

    spawner = fn ->
      port =
        Port.open({:spawn_executable, "/usr/bin/perl"}, [
          :binary,
          :exit_status,
          :hide,
          {:args, ["-e", script]}
        ])

      {:ok, port}
    end

    # Unregistered and addressed by pid: several of these run concurrently, and
    # generating a name per test would mint an atom per run.
    {:ok, pid} = CodexAppServer.start_link(name: nil, spawner: spawner)
    %{server: pid, pid: pid}
  end

  describe "thread lifecycle" do
    test "starts a thread and routes its turn events to the registering process" do
      %{server: server} = start_server()
      ref = make_ref()

      assert {:ok, @thread} = CodexAppServer.start_thread(server, ref, [])

      # Deliberately asserted on a TURN event, not `thread/started`: codex emits
      # that one before the caller can possibly be registered against the thread
      # id it announces, so it is always dropped. The thread id comes from the
      # response instead. See the ordering note in `CodexAppServer`.
      {:ok, _turn} = CodexAppServer.start_turn(server, @thread, "hello")
      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :assistant_text}}, 2000
    end

    test "resumes a known thread, which is what gives codex conversation continuity" do
      %{server: server} = start_server()
      ref = make_ref()

      # Under `codex exec` this was impossible: resume is a subcommand, so every
      # turn started fresh and the chat forgot the previous one.
      assert {:ok, @thread} = CodexAppServer.resume_thread(server, ref, @thread, [])
      assert {:ok, _turn} = CodexAppServer.start_turn(server, @thread, "hello")
    end
  end

  describe "turns" do
    setup do
      ctx = start_server()
      ref = make_ref()
      {:ok, @thread} = CodexAppServer.start_thread(ctx.server, ref, [])
      Map.put(ctx, :ref, ref)
    end

    test "turn/start returns as soon as the turn exists, then streams", %{
      server: server,
      ref: ref
    } do
      assert {:ok, @turn} = CodexAppServer.start_turn(server, @thread, "do the thing")

      # The work arrives afterwards as notifications — which is precisely what
      # makes the turn addressable while it runs.
      assert_receive {:chat_event, ^ref,
                      %StreamEvent{kind: :assistant_text, text: "working on it"}},
                     2000
    end

    test "steering the CURRENT turn is accepted", %{server: server} do
      {:ok, turn} = CodexAppServer.start_turn(server, @thread, "first")
      assert {:ok, ^turn} = CodexAppServer.steer(server, @thread, turn, "actually, stop")
    end

    test "a stale expectedTurnId is refused as :no_active_turn", %{server: server} do
      {:ok, _turn} = CodexAppServer.start_turn(server, @thread, "first")

      # -32600 covers both protocol refusals — wrong id, and no active turn.
      # `Chat` treats them identically: the message becomes the next turn rather
      # than being applied to one the operator never saw.
      assert CodexAppServer.steer(server, @thread, "some-other-turn", "late") ==
               {:error, :no_active_turn}
    end

    test "interrupt stops the turn without touching the thread", %{server: server} do
      {:ok, turn} = CodexAppServer.start_turn(server, @thread, "first")
      assert :ok = CodexAppServer.interrupt(server, @thread, turn)

      # The thread survives, so the next turn continues the conversation.
      assert {:ok, _next} = CodexAppServer.start_turn(server, @thread, "second")
    end
  end

  describe "routing" do
    test "events for an unregistered thread are dropped, not crashed on" do
      %{server: server, pid: pid} = start_server()
      ref = make_ref()
      {:ok, @thread} = CodexAppServer.start_thread(server, ref, [])

      CodexAppServer.unregister(server, ref)
      _ = :sys.get_state(pid)

      {:ok, _turn} = CodexAppServer.start_turn(server, @thread, "hello")

      # Nothing routed anywhere, and the connection is still alive — an
      # unattributable notification is a codex release adding a feature, not an
      # error worth taking the connection down for.
      refute_receive {:chat_event, ^ref, _event}, 200
      assert Process.alive?(pid)
    end

    test "two conversations on one connection do not see each other's events" do
      %{server: server} = start_server()
      ref_a = make_ref()

      {:ok, @thread} = CodexAppServer.start_thread(server, ref_a, [])

      # A second registration for the same thread replaces the first — the
      # multiplexing key is the thread, and this is what stops a stale tab
      # keeping a claim on the stream.
      ref_b = make_ref()
      {:ok, @thread} = CodexAppServer.resume_thread(server, ref_b, @thread, [])
      {:ok, _turn} = CodexAppServer.start_turn(server, @thread, "hello")

      assert_receive {:chat_event, ^ref_b, %StreamEvent{kind: :assistant_text}}, 2000
      refute_receive {:chat_event, ^ref_a, %StreamEvent{kind: :assistant_text}}, 200
    end
  end

  describe "connection failure" do
    test "every registered conversation is told when the connection dies" do
      %{server: server, pid: pid} = start_server()
      Process.unlink(pid)
      ref = make_ref()
      {:ok, @thread} = CodexAppServer.start_thread(server, ref, [])

      # Kill the child out from under the connection. Signalled by pid rather
      # than `Port.close/1`, which only the owning process may call.
      state = :sys.get_state(pid)
      {:os_pid, os_pid} = Port.info(state.port, :os_pid)
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      # A hang is the failure mode that matters here: an in-flight turn must
      # fail visibly rather than waiting forever on a connection that is gone.
      assert_receive {:chat_transport_down, ^ref, _reason}, 2000
    end
  end
end
