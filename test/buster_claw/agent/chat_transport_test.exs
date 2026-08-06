defmodule BusterClaw.Agent.ChatTransportTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.ChatTransport

  # Capture what an adapter would spawn, without spawning anything. This is the
  # whole point of the suite below: Phase 1 moved argv construction out of
  # `Chat.start_run/2`, and the only thing that makes that safe is proving the
  # argv did not change on the way.
  defp capture(agent, opts \\ []) do
    parent = self()

    spawner = fn prompt, spawn_opts ->
      send(parent, {:spawned, prompt, spawn_opts})
      {:ok, make_ref()}
    end

    mod = adapter(agent)

    {:ok, handle} =
      mod.open(opts |> Keyword.put(:spawner, spawner) |> Keyword.put_new(:agent, agent))

    {:ok, _handle, _ref} = mod.start_turn(handle, "hello")

    assert_received {:spawned, prompt, spawn_opts}
    %{prompt: prompt, args: Keyword.fetch!(spawn_opts, :extra_args), opts: spawn_opts}
  end

  defp adapter(:codex), do: ChatTransport.Codex
  defp adapter(:opencode), do: ChatTransport.OpenCode
  defp adapter(_claude_or_unknown), do: ChatTransport.Claude

  defp capabilities_for(agent), do: adapter(agent).capabilities()
  defp steerable_for?(agent), do: :steer in capabilities_for(agent).modes

  # Start a real conversation and report the argv it actually spawned. The
  # harness → adapter mapping lives in `Chat` (private, to keep the transport
  # files acyclic), so this is what proves `Chat` reaches for the right adapter —
  # asserting a mapping against a copy of the mapping would prove nothing.
  defp argv_through_chat(agent) do
    parent = self()

    spawner = fn _prompt, spawn_opts ->
      send(parent, {:spawned, spawn_opts})
      {:ok, make_ref()}
    end

    conv_id = "sel-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Chat.start_link(
        conv_id: conv_id,
        spawner: spawner,
        persist: false,
        audit: false,
        agent: agent
      )

    :ok = Chat.send_message(conv_id, "hello")
    assert_receive {:spawned, spawn_opts}
    Keyword.fetch!(spawn_opts, :extra_args)
  end

  describe "adapter selection" do
    test "Chat reaches for each backend's own adapter" do
      # Each backend's streaming flag is distinctive, so the argv alone
      # identifies which adapter ran.
      assert argv_through_chat(:claude) == ["--output-format", "stream-json", "--verbose"]
      assert argv_through_chat(:codex) == ["--json"]
      assert argv_through_chat(:opencode) == ["--format", "json"]
    end

    test "an unknown backend reads as claude rather than crashing the conversation" do
      # Same rule as `StreamEvent.parse/2`: every caller predates harness
      # selection, and claude's shape is the one they were written against. The
      # argv comes out empty only because `AgentBackend.stream_args/2` has no
      # clause for an unrecognised name — the same latent gap covered below.
      assert argv_through_chat(:some_future_cli) == []
    end
  end

  describe "an unresolved agent" do
    test "reaches AgentRunner as nil so detection still runs" do
      # `nil` means "let `AgentRunner.detect/0` decide" — it honours the
      # `:agent_cli` test override and PATH order. Passing the adapter's own name
      # instead turns detection into a hard `{:agent_unavailable, :claude}` on a
      # machine that only has codex, and quietly bypasses the stand-in CLI the
      # model-policy wiring test depends on. Regression guard: this is exactly
      # the bug the extraction introduced once.
      assert %{opts: opts} = capture(nil)
      assert Keyword.fetch!(opts, :agent) == nil
    end

    test "emits NO streaming flags — preserved from before the extraction" do
      # ⚠ LATENT BUG, deliberately preserved by Phase 1 rather than fixed inside
      # a refactor. `AgentBackend.stream_args/2` has no clause for nil, so it
      # falls through to `[]`: a chat started without an explicit `:agent` runs
      # WITHOUT `--output-format stream-json`, every output line fails to parse,
      # and the whole reply lands in `raw_tail` instead of the transcript.
      #
      # It is masked in the app because every real caller passes a resolved
      # backend (`ModelPolicy.backend_for(:chat)`). Fixing it is a one-word
      # change — `for_agent/1` already maps nil to claude — but it is a
      # behaviour change and belongs in its own commit, not smuggled into a
      # boundary extraction.
      assert %{args: []} = capture(nil)
    end
  end

  describe "claude argv" do
    test "streams, resumes with --resume, and takes the guide as a flag" do
      %{prompt: prompt, args: args} =
        capture(:claude, session_id: "sess-1", append_system_prompt: "GUIDE")

      assert args == [
               "--output-format",
               "stream-json",
               "--verbose",
               "--resume",
               "sess-1",
               "--append-system-prompt",
               "GUIDE"
             ]

      # claude is the one backend that can take the guide as a flag, so the
      # prompt stays exactly what the operator typed.
      assert prompt == "hello"
    end

    test "omits resume on the first turn and the guide when there is none" do
      assert %{args: ["--output-format", "stream-json", "--verbose"]} = capture(:claude)
    end

    test "carries extra_cli_args last, after the streaming and resume flags" do
      %{args: args} =
        capture(:claude, session_id: "s", extra_cli_args: ["--strict-mcp-config", "--mcp-config"])

      assert List.last(args) == "--mcp-config"
      assert Enum.at(args, -2) == "--strict-mcp-config"
    end

    test "passes a stricter permission mode through to the spawn opts" do
      assert %{opts: opts} = capture(:claude, permission_mode: "dontAsk")
      assert Keyword.fetch!(opts, :permission_mode) == "dontAsk"
    end

    test "omits permission_mode entirely when unset, leaving AgentRunner's default" do
      assert %{opts: opts} = capture(:claude)
      refute Keyword.has_key?(opts, :permission_mode)
    end
  end

  describe "codex argv" do
    test "streams with --json, does NOT resume, and prepends the guide to the prompt" do
      %{prompt: prompt, args: args} =
        capture(:codex, session_id: "thread-1", append_system_prompt: "GUIDE")

      assert args == ["--json"]

      # `codex exec resume <id>` is a SUBCOMMAND, not a flag — appending one
      # would be rejected outright, so a codex chat starts fresh each turn.
      refute "--resume" in args
      refute "thread-1" in args

      # And codex rejects --append-system-prompt (exit 2), so the guide rides in
      # the prompt instead. Losing it silently is what this asserts against.
      assert prompt == "GUIDE\n\n---\n\nhello"
    end

    test "leaves the prompt alone when the conversation carries no guide" do
      assert %{prompt: "hello"} = capture(:codex)
    end
  end

  describe "opencode argv" do
    test "streams with --format json and resumes with --session" do
      %{prompt: prompt, args: args} =
        capture(:opencode, session_id: "ses-1", append_system_prompt: "GUIDE")

      assert args == ["--format", "json", "--session", "ses-1"]
      assert prompt == "GUIDE\n\n---\n\nhello"
    end

    test "omits --session on the first turn" do
      assert %{args: ["--format", "json"]} = capture(:opencode)
    end
  end

  describe "duplex argv" do
    test "drops the positional prompt and asks for streaming INPUT" do
      argv = BusterClaw.AgentBackend.argv(:claude, "hello", duplex: true, stream: true)

      # No positional prompt: it arrives as JSONL on stdin instead, and passing
      # both would hand claude the first message twice.
      refute "hello" in argv

      assert argv == [
               "-p",
               "--permission-mode",
               "bypassPermissions",
               "--output-format",
               "stream-json",
               "--verbose",
               "--input-format",
               "stream-json",
               "--replay-user-messages"
             ]
    end

    test "keeps the same permission posture as the one-shot path" do
      duplex =
        BusterClaw.AgentBackend.argv(:claude, "hi", duplex: true, permission_mode: "dontAsk")

      one_shot = BusterClaw.AgentBackend.argv(:claude, "hi", permission_mode: "dontAsk")

      # The confinement flags must be identical — a transport swap is not
      # permission to run with a different posture.
      assert "dontAsk" in duplex
      assert "dontAsk" in one_shot
    end

    test "the model flag still applies, so ModelPolicy is not bypassed" do
      argv =
        BusterClaw.AgentBackend.argv(:claude, "hi",
          duplex: true,
          stream: true,
          model: "claude-opus-5"
        )

      assert "--model" in argv
      assert "claude-opus-5" in argv
    end

    test "only claude has a duplex mode; the others get ordinary streaming flags" do
      assert BusterClaw.AgentBackend.stream_args(:codex, stream: true, duplex: true) == ["--json"]

      assert BusterClaw.AgentBackend.stream_args(:opencode, stream: true, duplex: true) ==
               ["--format", "json"]
    end
  end

  describe "capabilities" do
    test "every backend offers queue-next, which is Buster Claw's own behaviour" do
      for agent <- [:claude, :codex, :opencode] do
        caps = capabilities_for(agent)
        assert :queue_next in caps.modes, "#{agent} must always offer queue-next"
        assert :start_turn in caps.modes
        assert :interrupt in caps.modes
      end
    end

    test "no backend claims steering or a receipt while Phase 1 is one-shot" do
      # Phase 0 measured all three harnesses steering. None of them can yet,
      # because the transports are still one-shot — and advertising a capability
      # the transport cannot honour is exactly the UI-that-lies failure this
      # roadmap exists to prevent. Phase 2 flips claude's entry; when it does,
      # this test is the one that should be updated deliberately.
      for agent <- [:claude, :codex, :opencode] do
        caps = capabilities_for(agent)
        refute :steer in caps.modes, "#{agent} must not advertise steering yet"
        assert caps.receipt == :none
        refute steerable_for?(agent)
      end
    end
  end

  describe "steer/3" do
    test "is unsupported on every Phase 1 adapter" do
      for agent <- [:claude, :codex, :opencode] do
        mod = adapter(agent)
        {:ok, handle} = mod.open([])
        assert mod.steer(handle, make_ref(), "redirect") == {:error, :not_supported}
      end
    end
  end

  describe "put_session/2" do
    test "records a binary id and ignores anything else" do
      handle = ChatTransport.build(:claude, [])

      assert ChatTransport.put_session(handle, "sess-9").session_id == "sess-9"
      assert ChatTransport.put_session(handle, nil).session_id == nil

      # A stale run's event can arrive after the handle is cleared; that must not
      # take the conversation down.
      assert ChatTransport.put_session(nil, "sess-9") == nil
    end
  end
end
