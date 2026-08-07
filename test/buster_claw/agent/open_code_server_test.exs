defmodule BusterClaw.Agent.OpenCodeServerTest do
  @moduledoc """
  The OpenCode server connection, with the HTTP layer and the process boot both
  injected.

  What is actually under test is the part Phase 0 said would be easy to get
  wrong: **acceptance**. `prompt_async` answers with an empty body, so nothing
  in the HTTP exchange proves a message landed. The receipt is an SSE echo, and
  everything here is about not confusing the two.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.OpenCodeServer
  alias BusterClaw.Agent.StreamEvent

  @session "ses_02fb28f3effeOQ3MnHKewJjbIt"

  defp start_server(overrides \\ []) do
    parent = self()

    booter = fn password ->
      send(parent, {:booted, password})
      {:ok, nil, "http://127.0.0.1:4999"}
    end

    http = fn req ->
      send(parent, {:http, req})

      cond do
        String.ends_with?(req.url, "/session") -> {:ok, %{"id" => @session}}
        # An EMPTY body, exactly as measured. Success, and not a receipt.
        String.ends_with?(req.url, "/prompt_async") -> {:ok, %{}}
        true -> {:ok, %{}}
      end
    end

    # No real socket: the suite drives the stream by sending `:sse_chunk`
    # directly, which is also how it controls event ORDER precisely.
    sse_starter = fn _parent, _base, _password -> nil end

    opts =
      Keyword.merge([name: nil, booter: booter, http: http, sse_starter: sse_starter], overrides)

    {:ok, pid} = OpenCodeServer.start_link(opts)
    %{server: pid, pid: pid}
  end

  # Push an SSE payload in as though it came off the stream.
  defp sse(ctx, event) do
    send(ctx.pid, {:sse_chunk, "data: " <> Jason.encode!(event) <> "\n"})
    _ = :sys.get_state(ctx.pid)
    :ok
  end

  defp user_echo(message_id),
    do: %{
      "type" => "message.updated",
      "properties" => %{
        "info" => %{"id" => message_id, "role" => "user", "sessionID" => @session}
      }
    }

  describe "boot" do
    test "generates a fresh password per boot and never puts it in argv" do
      ctx = start_server()
      {:ok, _id} = OpenCodeServer.create_session(ctx.server, make_ref(), [])

      assert_receive {:booted, password}
      assert is_binary(password)
      assert byte_size(password) > 20
    end

    test "authenticates as the literal user `opencode`" do
      ctx = start_server()
      {:ok, _id} = OpenCodeServer.create_session(ctx.server, make_ref(), [])

      # Measured: an empty username is rejected with 401. This is not a
      # placeholder — it is the username the server expects.
      assert_receive {:http, %{auth: {"opencode", _password}}}
    end
  end

  describe "confinement" do
    test "a session naming an agent file is REFUSED, not run unconfined" do
      ctx = start_server()

      # Phase 0: the server accepts a bogus agent, echoes it back on create AND
      # re-fetch, then admits a prompt — so asking for confinement here would
      # silently get `{"*", allow, "*"}`. Refusing is the only honest answer.
      assert OpenCodeServer.create_session(ctx.server, make_ref(), agent: "trading-readonly") ==
               {:error, :confinement_unsupported}

      # And nothing was created.
      refute_receive {:http, _req}, 100
    end
  end

  describe "acceptance receipts" do
    setup do
      ctx = start_server()
      ref = make_ref()
      {:ok, @session} = OpenCodeServer.create_session(ctx.server, ref, [])
      Map.put(ctx, :ref, ref)
    end

    test "prompt returns a message id, which is NOT a receipt", %{server: server} do
      assert {:ok, message_id} = OpenCodeServer.prompt(server, @session, "hello")
      assert String.starts_with?(message_id, "msg_")

      # The id we supplied went on the wire — that is what makes the echo
      # attributable to this message rather than any other.
      assert_receive {:http, %{json: %{"messageID" => ^message_id}}}

      # Nothing has confirmed anything yet.
      assert OpenCodeServer.await_receipt(message_id, message_id, 50) == {:error, :timeout}
    end

    test "the SSE echo of OUR message id is the receipt", %{server: server, ref: ref} = ctx do
      {:ok, message_id} = OpenCodeServer.prompt(server, @session, "hello")

      sse(ctx, user_echo(message_id))

      assert OpenCodeServer.await_receipt(ref, message_id, 500) == :ok
    end

    test "an echo for a DIFFERENT message is not this message's receipt",
         %{server: server, ref: ref} = ctx do
      {:ok, message_id} = OpenCodeServer.prompt(server, @session, "hello")

      sse(ctx, user_echo("msg_someone_else"))

      assert OpenCodeServer.await_receipt(ref, message_id, 100) == {:error, :timeout}
    end

    test "an assistant message is never mistaken for a receipt",
         %{server: server, ref: ref} = ctx do
      {:ok, message_id} = OpenCodeServer.prompt(server, @session, "hello")

      sse(ctx, %{
        "type" => "message.updated",
        "properties" => %{
          "info" => %{"id" => message_id, "role" => "assistant", "sessionID" => @session}
        }
      })

      assert OpenCodeServer.await_receipt(ref, message_id, 100) == {:error, :timeout}
    end
  end

  describe "event routing" do
    setup do
      ctx = start_server()
      ref = make_ref()
      {:ok, @session} = OpenCodeServer.create_session(ctx.server, ref, [])
      Map.put(ctx, :ref, ref)
    end

    test "an assistant text part becomes assistant text", %{ref: ref} = ctx do
      sse(ctx, %{
        "type" => "message.updated",
        "properties" => %{
          "info" => %{"id" => "msg_a", "role" => "assistant", "sessionID" => @session}
        }
      })

      sse(ctx, %{
        "type" => "message.part.updated",
        "properties" => %{
          "part" => %{
            "type" => "text",
            "text" => "on it",
            "messageID" => "msg_a",
            "sessionID" => @session
          }
        }
      })

      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :assistant_text, text: "on it"}}
    end

    test "a text part whose message is the USER'S is not echoed into the transcript",
         %{ref: ref} = ctx do
      # Otherwise the operator's own message would appear twice.
      sse(ctx, user_echo("msg_u"))

      sse(ctx, %{
        "type" => "message.part.updated",
        "properties" => %{
          "part" => %{
            "type" => "text",
            "text" => "what I typed",
            "messageID" => "msg_u",
            "sessionID" => @session
          }
        }
      })

      refute_receive {:chat_event, ^ref, %StreamEvent{kind: :assistant_text}}, 100
    end

    test "session.idle is the turn boundary and carries the turn's summed cost",
         %{ref: ref} = ctx do
      sse(ctx, %{
        "type" => "message.updated",
        "properties" => %{
          "info" => %{"id" => "msg_a", "role" => "assistant", "sessionID" => @session}
        }
      })

      # OpenCode reports cost per STEP, so the connection sums them — otherwise
      # a turn's spend could only be shown by inventing a number.
      for cost <- [0.002, 0.003] do
        sse(ctx, %{
          "type" => "message.part.updated",
          "properties" => %{
            "part" => %{
              "type" => "step-finish",
              "cost" => cost,
              "messageID" => "msg_a",
              "sessionID" => @session
            }
          }
        })
      end

      sse(ctx, %{"type" => "session.idle", "properties" => %{"sessionID" => @session}})

      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :result, cost_usd: cost}}
      assert_in_delta cost, 0.005, 0.0001
    end

    test "a tool is announced ONCE, however many part updates it gets", %{ref: ref} = ctx do
      sse(ctx, %{
        "type" => "message.updated",
        "properties" => %{
          "info" => %{"id" => "msg_a", "role" => "assistant", "sessionID" => @session}
        }
      })

      # Exactly the sequence the acceptance smoke produced: an update with no
      # arguments yet, then the same part several times as its state advances.
      # Claude and Codex each emit one transcript line per tool call, so
      # forwarding all of these would make opencode the odd one out — the smoke
      # showed eight lines for two commands.
      part = fn status, input ->
        %{
          "type" => "message.part.updated",
          "properties" => %{
            "part" => %{
              "type" => "tool",
              "id" => "prt_1",
              "tool" => "bash",
              "messageID" => "msg_a",
              "sessionID" => @session,
              "state" => %{"status" => status, "input" => input}
            }
          }
        }
      end

      sse(ctx, part.("pending", %{}))
      sse(ctx, part.("running", %{"command" => "sleep 8 && echo step-one"}))
      sse(ctx, part.("running", %{"command" => "sleep 8 && echo step-one"}))
      sse(ctx, part.("completed", %{"command" => "sleep 8 && echo step-one"}))

      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :tool_use, summary: summary}}
      assert summary =~ "sleep 8"

      # The bare-name update never reaches the transcript, and neither do the
      # repeats.
      refute_receive {:chat_event, ^ref, %StreamEvent{kind: :tool_use}}, 100
    end

    test "a tool that completes with no arguments is still announced once", %{ref: ref} = ctx do
      sse(ctx, %{
        "type" => "message.updated",
        "properties" => %{
          "info" => %{"id" => "msg_a", "role" => "assistant", "sessionID" => @session}
        }
      })

      # Suppressing empty-input updates must not swallow a tool that genuinely
      # has none — it would vanish from the transcript entirely.
      sse(ctx, %{
        "type" => "message.part.updated",
        "properties" => %{
          "part" => %{
            "type" => "tool",
            "id" => "prt_2",
            "tool" => "list",
            "messageID" => "msg_a",
            "sessionID" => @session,
            "state" => %{"status" => "completed", "input" => %{}}
          }
        }
      })

      assert_receive {:chat_event, ^ref, %StreamEvent{tool: "list"}}
    end

    test "a NEW turn can announce its tools again", %{ref: ref} = ctx do
      sse(ctx, %{
        "type" => "message.updated",
        "properties" => %{
          "info" => %{"id" => "msg_a", "role" => "assistant", "sessionID" => @session}
        }
      })

      tool = fn id ->
        %{
          "type" => "message.part.updated",
          "properties" => %{
            "part" => %{
              "type" => "tool",
              "id" => id,
              "tool" => "bash",
              "messageID" => "msg_a",
              "sessionID" => @session,
              "state" => %{"status" => "running", "input" => %{"command" => "ls"}}
            }
          }
        }
      end

      sse(ctx, tool.("prt_a"))
      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :tool_use}}

      sse(ctx, %{"type" => "session.idle", "properties" => %{"sessionID" => @session}})
      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :result}}

      sse(ctx, tool.("prt_b"))
      assert_receive {:chat_event, ^ref, %StreamEvent{kind: :tool_use}}
    end

    test "events for an unregistered session are dropped, not crashed on", ctx do
      OpenCodeServer.unregister(ctx.server, ctx.ref)
      _ = :sys.get_state(ctx.pid)

      sse(ctx, %{"type" => "session.idle", "properties" => %{"sessionID" => @session}})

      ref = ctx.ref
      refute_receive {:chat_event, ^ref, _event}, 100
      assert Process.alive?(ctx.pid)
    end
  end

  describe "the SSE reader" do
    test "a dropped stream schedules a reconnect rather than taking the server down" do
      ctx = start_server()
      {:ok, @session} = OpenCodeServer.create_session(ctx.server, make_ref(), [])

      send(ctx.pid, {:sse_down, {:error, :closed}})
      _ = :sys.get_state(ctx.pid)

      # A blip must not become an outage: the connection stays up and retries.
      assert Process.alive?(ctx.pid)
      assert :sys.get_state(ctx.pid).sse == nil
    end
  end
end
