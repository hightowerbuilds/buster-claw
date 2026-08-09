defmodule BusterClaw.Agent.ChatAttachmentWiringTest do
  @moduledoc """
  The last mile: a file staged by the composer actually reaching the CLI.

  Every assertion below is on what left the BEAM — the argv handed to the
  spawner, or the JSONL bytes written to a real pipe. Asserting on an
  intermediate map would prove the wiring agrees with itself, which is exactly
  what was true while this feature did nothing at all.
  """

  # async: false — points the global :attachments_root at a tmp dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Agent.Attachments
  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.ChatTransport

  # A one-pixel PNG header: enough for the store to sniff `image/png` and
  # classify it `:image`, which is all any delivery decision reads.
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1>>
  @pdf <<"%PDF-1.7\n1 0 obj\n">>

  # The argv every claude chat turn has spawned since the transport extraction.
  # Written out rather than computed, because the point of the no-attachment
  # assertions is that this list is untouched.
  @claude_args ["--output-format", "stream-json", "--verbose"]

  setup do
    root = Path.join(System.tmp_dir!(), "bc_chat_attach_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :attachments_root)
    Application.put_env(:buster_claw, :attachments_root, Path.join(root, "staging"))

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:buster_claw, :attachments_root)
        value -> Application.put_env(:buster_claw, :attachments_root, value)
      end

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # --- harness ---------------------------------------------------------------

  defp new_conv, do: "attach-#{System.unique_integer([:positive])}"

  # Reports the prompt and options of every spawn, and never finishes, so the
  # conversation stays on the turn under test.
  defp capturing_spawner(parent) do
    fn prompt, opts ->
      port = make_ref()
      send(parent, {:spawned, port, prompt, opts})
      {:ok, port}
    end
  end

  defp start_chat(conv_id, opts) do
    {:ok, pid} =
      Chat.start_link(
        [
          conv_id: conv_id,
          spawner: capturing_spawner(self()),
          persist: false,
          audit: false
        ] ++ opts
      )

    pid
  end

  defp spawned do
    assert_receive {:spawned, port, prompt, opts}
    %{port: port, prompt: prompt, args: Keyword.fetch!(opts, :extra_args)}
  end

  defp stage!(conv_id, filename, media_type, bytes) do
    {:ok, attachment} =
      Attachments.stage(
        conv_id,
        %{filename: filename, media_type: media_type, source: :upload},
        {:bytes, bytes}
      )

    attachment
  end

  # What the composer holds: an id and some display metadata, and deliberately no
  # path. This is the shape `Status.Chat` submits, so it is the shape the
  # resolution has to survive.
  defp composer_chip(attachment), do: Map.take(attachment, [:id, :filename, :bytes, :kind])

  # --- the property everything else rests on ---------------------------------

  describe "a turn with no attachments" do
    test "spawns byte-identical argv and an untouched prompt" do
      conv = new_conv()
      start_chat(conv, agent: :claude)

      assert {:ok, :started} = Chat.submit(conv, "hello", delivery: :auto)

      assert %{prompt: "hello", args: @claude_args} = spawned()
    end

    test "an explicit empty list is the same as not passing one" do
      conv = new_conv()
      start_chat(conv, agent: :claude)

      assert {:ok, :started} = Chat.submit(conv, "hello", delivery: :auto, attachments: [])

      assert %{prompt: "hello", args: @claude_args} = spawned()
    end

    test "send_message/2, which cannot carry one, is unaffected" do
      conv = new_conv()
      start_chat(conv, agent: :claude)

      assert :ok = Chat.send_message(conv, "hello")

      assert %{prompt: "hello", args: @claude_args} = spawned()
    end
  end

  # --- per-backend delivery, asserted on the argv ----------------------------

  describe "claude on the default (-p) path" do
    test "grants the staging directory and names the file in the prompt" do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      start_chat(conv, agent: :claude)

      # The COMPOSER's shape, so this covers the id → store resolution the
      # shipped path depends on.
      assert {:ok, :started} =
               Chat.submit(conv, "what is this?",
                 delivery: :auto,
                 attachments: [composer_chip(attachment)]
               )

      assert %{prompt: prompt, args: args} = spawned()

      # claude has no attachment flag at all: the grant is what makes a path
      # outside the working root readable.
      assert args == @claude_args ++ ["--add-dir", Path.dirname(attachment.path)]

      assert prompt =~ "The user attached these files"
      assert prompt =~ attachment.path
      assert prompt =~ "shot.png"
      # The operator's own words survive intact, and last.
      assert String.ends_with?(prompt, "what is this?")
    end

    test "one grant per directory, not one per file" do
      conv = new_conv()
      first = stage!(conv, "a.png", "image/png", @png)
      second = stage!(conv, "b.png", "image/png", @png)
      start_chat(conv, agent: :claude)

      assert {:ok, :started} =
               Chat.submit(conv, "compare these", delivery: :auto, attachments: [first, second])

      assert %{prompt: prompt, args: args} = spawned()
      assert args == @claude_args ++ ["--add-dir", Path.dirname(first.path)]
      assert prompt =~ first.path
      assert prompt =~ second.path
    end
  end

  describe "codex" do
    test "attaches images with -i and adds nothing to the prompt" do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      start_chat(conv, agent: :codex)

      assert {:ok, :started} =
               Chat.submit(conv, "what is this?", delivery: :auto, attachments: [attachment])

      assert %{prompt: prompt, args: args} = spawned()
      assert args == ["--json", "-i", attachment.path]
      assert prompt == "what is this?"
    end

    test "a PDF is named by path instead — `-i` is an image decoder" do
      conv = new_conv()
      attachment = stage!(conv, "paper.pdf", "application/pdf", @pdf)
      start_chat(conv, agent: :codex)

      assert {:ok, :started} =
               Chat.submit(conv, "summarise it", delivery: :auto, attachments: [attachment])

      assert %{prompt: prompt, args: args} = spawned()
      # Refusing to attach one file must never cost the operator their turn, and
      # a PDF through `-i` is a decode failure that would.
      assert args == ["--json"]
      assert prompt =~ attachment.path
      assert String.ends_with?(prompt, "summarise it")
    end
  end

  describe "opencode" do
    test "attaches with -f, which takes any file" do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      start_chat(conv, agent: :opencode)

      assert {:ok, :started} =
               Chat.submit(conv, "what is this?", delivery: :auto, attachments: [attachment])

      assert %{prompt: prompt, args: args} = spawned()
      assert args == ["--format", "json", "-f", attachment.path]
      assert prompt == "what is this?"
    end
  end

  # --- the streaming path, asserted on the bytes -----------------------------

  describe "claude on the streaming (duplex) path" do
    setup do
      sink = Path.join(System.tmp_dir!(), "bc_duplex_#{System.unique_integer([:positive])}.jsonl")
      on_exit(fn -> File.rm(sink) end)
      {:ok, sink: sink}
    end

    # A real pipe into a real process, so what is asserted is what
    # `Port.command/2` actually wrote. `cat` stands in for claude's stdin.
    defp sink_spawner(parent, sink) do
      fn _prompt, opts ->
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            :hide,
            {:args, ["-c", "cat > #{sink}"]}
          ])

        send(parent, {:spawned, port, "", opts})
        {:ok, port}
      end
    end

    defp start_duplex_chat(conv_id, sink) do
      {:ok, pid} =
        Chat.start_link(
          conv_id: conv_id,
          spawner: sink_spawner(self(), sink),
          transport_mod: ChatTransport.ClaudeDuplex,
          agent: :claude,
          persist: false,
          audit: false
        )

      pid
    end

    defp written_lines(sink, count, deadline \\ 40) do
      lines =
        case File.read(sink) do
          {:ok, contents} -> String.split(contents, "\n", trim: true)
          _error -> []
        end

      cond do
        length(lines) >= count ->
          lines

        deadline == 0 ->
          flunk("expected #{count} JSONL line(s), got #{inspect(lines)}")

        true ->
          # The write happened in another OS process; poll rather than guess.
          Process.sleep(25)
          written_lines(sink, count, deadline - 1)
      end
    end

    test "an image becomes a base64 block in an ARRAY content", %{sink: sink} do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      start_duplex_chat(conv, sink)

      assert {:ok, :started} =
               Chat.submit(conv, "what is this?",
                 delivery: :auto,
                 attachments: [composer_chip(attachment)]
               )

      assert %{args: args} = spawned()
      # Nothing was granted: the bytes are ON THE WIRE, so no file needs to be
      # readable at all.
      refute "--add-dir" in args

      assert [line] = written_lines(sink, 1)

      assert %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "what is this?"},
                   %{
                     "type" => "image",
                     "source" => %{
                       "type" => "base64",
                       "media_type" => "image/png",
                       "data" => data
                     }
                   }
                 ]
               }
             } = Jason.decode!(line)

      assert Base.decode64!(data) == @png
    end

    test "with no attachment the line is the bare string it has always been", %{sink: sink} do
      conv = new_conv()
      start_duplex_chat(conv, sink)

      assert {:ok, :started} = Chat.submit(conv, "hello", delivery: :auto)
      assert %{args: args} = spawned()
      # The duplex argv, untouched by attachments existing.
      refute "--add-dir" in args

      assert [line] = written_lines(sink, 1)

      assert Jason.decode!(line) == %{
               "type" => "user",
               "message" => %{"role" => "user", "content" => "hello"}
             }
    end

    test "attachments ride with THEIR message and no message after it", %{sink: sink} do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      pid = start_duplex_chat(conv, sink)

      assert {:ok, :started} =
               Chat.submit(conv, "first", delivery: :auto, attachments: [attachment])

      assert %{port: port} = spawned()
      assert [_first] = written_lines(sink, 1)

      # End the turn the way a persistent transport does — on the result event,
      # not on a process exit. The process, and its handle, survive.
      send(pid, {port, {:data, ~s({"type":"result","subtype":"success","num_turns":1}\n)}})
      refute Chat.running?(conv)

      assert {:ok, :started} = Chat.submit(conv, "second", delivery: :auto)
      refute_receive {:spawned, _port, _prompt, _opts}, 50

      assert [_first, second] = written_lines(sink, 2)

      # The handle outlived the turn; the attachment did not.
      assert Jason.decode!(second) == %{
               "type" => "user",
               "message" => %{"role" => "user", "content" => "second"}
             }
    end
  end

  # --- the file that went away -----------------------------------------------

  describe "an attachment whose staged file vanished between send and spawn" do
    test "is dropped, and the turn runs exactly as if it had never been attached" do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      start_chat(conv, agent: :claude)

      # The window this covers is real: the composer staged the file, the user
      # hit send, and something removed it before the spawn.
      File.rm!(attachment.path)

      assert {:ok, :started} =
               Chat.submit(conv, "what is this?", delivery: :auto, attachments: [attachment])

      # No grant for a directory whose file is gone, and no path announced to a
      # model that would only go looking for nothing.
      assert %{prompt: "what is this?", args: @claude_args} = spawned()
    end

    test "is dropped by id as well as by record" do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      start_chat(conv, agent: :claude)

      File.rm!(attachment.path)

      assert {:ok, :started} =
               Chat.submit(conv, "what is this?",
                 delivery: :auto,
                 attachments: [composer_chip(attachment)]
               )

      assert %{prompt: "what is this?", args: @claude_args} = spawned()
    end

    test "an id belonging to another conversation never resolves" do
      mine = new_conv()
      theirs = new_conv()
      attachment = stage!(theirs, "shot.png", "image/png", @png)
      start_chat(mine, agent: :claude)

      # The scoping is the containment, and it is the store's: an id is only
      # ever resolved inside its own conversation's directory.
      assert {:ok, :started} =
               Chat.submit(mine, "what is this?",
                 delivery: :auto,
                 attachments: [composer_chip(attachment)]
               )

      assert %{prompt: "what is this?", args: @claude_args} = spawned()
    end
  end

  # --- the queue -------------------------------------------------------------

  describe "a queued message" do
    test "carries its attachments into the turn it eventually becomes" do
      conv = new_conv()
      attachment = stage!(conv, "shot.png", "image/png", @png)
      pid = start_chat(conv, agent: :claude)

      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert %{port: port, args: @claude_args} = spawned()

      assert {:ok, :queued} =
               Chat.submit(conv, "and this?", delivery: :next, attachments: [attachment])

      # One-shot transport: the turn ends when the process exits, and the queue
      # dispatches the next message as its own turn.
      send(pid, {port, {:exit_status, 0}})

      assert %{prompt: prompt, args: args} = spawned()
      assert args == @claude_args ++ ["--add-dir", Path.dirname(attachment.path)]
      assert String.ends_with?(prompt, "and this?")
    end
  end
end
