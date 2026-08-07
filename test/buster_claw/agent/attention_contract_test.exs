defmodule BusterClaw.Agent.AttentionContractTest do
  @moduledoc """
  The prompt half of steering: whether the model is told to expect live
  messages, and — just as important — whether it is told that on a backend where
  no such message can arrive.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.Agent.AttentionContract, as: Contract
  alias BusterClaw.Agent.ChatTransport

  describe "the contract text" do
    test "says the things the measurements say, and nothing they contradict" do
      text = Contract.text()

      # Measured: a steered message is acted on at the next TOOL boundary. The
      # wording has to describe that rather than ask for something no harness
      # can do.
      assert text =~ "next safe boundary"

      # Measured: injecting before a tool call did not stop that call starting —
      # the model had already committed. Replaying a completed side effect is a
      # real hazard, not a hypothetical.
      assert text =~ "already completed"

      # Polling was explicitly rejected while scoping: it spends tokens, adds
      # latency, and can still be forgotten. A model that WAITS reintroduces the
      # same cost through the prompt instead of the tool surface.
      assert text =~ "never wait or poll"

      # And it must not promise the one thing nothing here can deliver.
      refute text =~ "immediately"
      refute text =~ "interrupt you"
    end
  end

  describe "apply?/1" do
    test "only a transport that can steer earns the contract" do
      assert Contract.apply?(ChatTransport.ClaudeDuplex.capabilities())
      assert Contract.apply?(ChatTransport.CodexAppServer.capabilities())
      assert Contract.apply?(ChatTransport.OpenCodeServer.capabilities())
    end

    test "a one-shot transport does not" do
      # On these, a message submitted during a run becomes the NEXT TURN. Telling
      # the model to reconcile it mid-turn would describe a mechanism that does
      # not exist — the prompt-side version of the placebo button the composer
      # refuses to render.
      refute Contract.apply?(ChatTransport.Claude.capabilities())
      refute Contract.apply?(ChatTransport.Codex.capabilities())
      refute Contract.apply?(ChatTransport.OpenCode.capabilities())
      refute Contract.apply?(%{})
    end
  end

  describe "compose/2" do
    test "a steerable backend gets the guide AND the contract" do
      composed = Contract.compose("SVG GUIDE", true)

      assert composed =~ "SVG GUIDE"
      assert composed =~ Contract.text()
    end

    test "a steerable backend with no guide still gets the contract" do
      assert Contract.compose(nil, true) == Contract.text()
      assert Contract.compose("", true) == Contract.text()
    end

    test "a one-shot backend gets its guide unchanged, and nothing added" do
      assert Contract.compose("SVG GUIDE", false) == "SVG GUIDE"
      refute Contract.compose("SVG GUIDE", false) =~ "next safe boundary"
    end

    test "nothing to say produces nil, so a caller can omit the field entirely" do
      assert Contract.compose(nil, false) == nil
      assert Contract.compose("", false) == nil
    end
  end

  # The wiring, per backend. Each carries instructions through a different
  # mechanism, and the point of these is that the CONVERSATION'S OWN GUIDE
  # reaches the model too — both server transports were silently dropping it
  # until the contract needed the same channel.
  describe "every steerable transport actually carries it" do
    defmodule CapturingServer do
      @moduledoc false
      def start_thread(_s, _ref, opts), do: capture(:thread, opts, "thread-1")
      def resume_thread(_s, _ref, id, opts), do: capture(:thread, opts, id)
      def create_session(_s, _ref, opts), do: capture(:session, opts, "ses-1")
      def attach_session(_s, _ref, id), do: {:ok, id}
      def start_turn(_s, _id, _text, opts), do: capture(:turn, opts, "turn-1")
      def prompt(_s, _id, _text, opts), do: capture(:prompt, opts, "msg-1")
      def steer(_s, _id, turn, _text), do: {:ok, turn}
      def await_receipt(_ref, _id), do: :ok
      def interrupt(_s, _id, _t), do: :ok
      def abort(_s, _id), do: :ok
      def unregister(_s, _ref), do: :ok

      # Tagged by kind: an opencode conversation captures a session-create AND a
      # prompt, and an untagged assert_received would read the wrong one.
      defp capture(kind, opts, id) do
        send(self(), {:opts, kind, opts})
        {:ok, id}
      end
    end

    setup do
      Application.put_env(:buster_claw, :codex_app_server, CapturingServer)
      Application.put_env(:buster_claw, :open_code_server, CapturingServer)

      on_exit(fn ->
        Application.delete_env(:buster_claw, :codex_app_server)
        Application.delete_env(:buster_claw, :open_code_server)
      end)
    end

    test "claude duplex puts it in --append-system-prompt" do
      parent = self()

      # A real pipe: this transport writes the first message with
      # `Port.command/2`, which a bare ref cannot take.
      spawner = fn _prompt, opts ->
        send(parent, {:spawned, opts})

        {:ok,
         Port.open({:spawn_executable, "/bin/cat"}, [
           :binary,
           :exit_status,
           :hide,
           {:args, []}
         ])}
      end

      {:ok, handle} =
        ChatTransport.ClaudeDuplex.open(
          agent: :claude,
          spawner: spawner,
          append_system_prompt: "SVG GUIDE"
        )

      {:ok, handle, _turn} = ChatTransport.ClaudeDuplex.start_turn(handle, "hello")
      on_exit(fn -> ChatTransport.ClaudeDuplex.close(handle) end)

      assert_received {:spawned, opts}
      args = Keyword.fetch!(opts, :extra_args)

      idx = Enum.find_index(args, &(&1 == "--append-system-prompt"))
      assert idx, "claude duplex did not pass a system prompt at all"

      prompt = Enum.at(args, idx + 1)
      assert prompt =~ "SVG GUIDE"
      assert prompt =~ "next safe boundary"
    end

    test "codex puts it in developerInstructions on thread/start" do
      {:ok, handle} =
        ChatTransport.CodexAppServer.open(agent: :codex, append_system_prompt: "SVG GUIDE")

      {:ok, _handle, _turn} = ChatTransport.CodexAppServer.start_turn(handle, "hello")

      assert_received {:opts, :thread, thread_opts}
      instructions = Keyword.fetch!(thread_opts, :instructions)

      # The guide was being DROPPED entirely by this transport before the
      # contract needed the same channel — a conversation's vocabulary silently
      # missing on codex while it worked on claude.
      assert instructions =~ "SVG GUIDE"
      assert instructions =~ "next safe boundary"
    end

    test "opencode puts it in the prompt's system field, on every message" do
      {:ok, handle} =
        ChatTransport.OpenCodeServer.open(agent: :opencode, append_system_prompt: "SVG GUIDE")

      {:ok, handle, turn} = ChatTransport.OpenCodeServer.start_turn(handle, "hello")

      assert_received {:opts, :prompt, prompt_opts}
      assert Keyword.fetch!(prompt_opts, :system) =~ "SVG GUIDE"
      assert Keyword.fetch!(prompt_opts, :system) =~ "next safe boundary"

      # And on a STEER too — the message most likely to need the framing is the
      # one that redirects work already underway.
      {:ok, _handle, _receipt} = ChatTransport.OpenCodeServer.steer(handle, turn, "redirect")

      assert_received {:opts, :prompt, steer_opts}
      assert Keyword.fetch!(steer_opts, :system) =~ "next safe boundary"
    end
  end
end
