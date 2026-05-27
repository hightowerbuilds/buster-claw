defmodule BusterClaw.CommandsTest do
  use BusterClaw.DataCase

  alias BusterClaw.Commands
  alias BusterClaw.Commands.Result
  alias BusterClaw.Google
  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Library
  alias BusterClaw.Providers

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "list_commands/0" do
    test "returns a structured catalog with representative commands" do
      catalog = Commands.list_commands()
      assert is_list(catalog)
      assert Enum.all?(catalog, &Map.has_key?(&1, :name))
      assert Enum.all?(catalog, &Map.has_key?(&1, :type))
      assert Enum.all?(catalog, &Map.has_key?(&1, :tier))
      assert Enum.all?(catalog, &Map.has_key?(&1, :description))
      assert Enum.all?(catalog, &Map.has_key?(&1, :args))

      names = catalog |> Enum.map(& &1.name) |> MapSet.new()

      for representative <- representative_commands() do
        assert MapSet.member?(names, representative),
               "expected catalog to include #{representative}"
      end

      assert %{type: :read, tier: :safe} = Enum.find(catalog, &(&1.name == "runtime_status"))

      assert %{type: :trigger, tier: :restricted} =
               Enum.find(catalog, &(&1.name == "analysis_run_pending"))
    end

    test "every command has a unique name" do
      names = Enum.map(Commands.list_commands(), & &1.name)
      assert names == Enum.uniq(names)
    end

    test "every command name matches a function in the module" do
      for %{name: name} <- Commands.list_commands() do
        assert function_exported?(Commands, String.to_atom(name), 1),
               "missing implementation for command #{name}/1"
      end
    end

    test "every command has tier safe or restricted" do
      for %{name: name, tier: tier} <- Commands.list_commands() do
        assert tier in [:safe, :restricted],
               "command #{name} has unexpected tier #{inspect(tier)}"
      end
    end

    test "serializes nested status tuples for API/MCP command results" do
      assert %{
               "items" => [
                 %{status: "ok", value: %{"id" => 1}},
                 %{status: "error", value: :failed}
               ]
             } = Result.to_json(%{"items" => [{:ok, %{"id" => 1}}, {:error, :failed}]})
    end
  end

  describe "call/2 dispatcher" do
    test "dispatches to the matching command" do
      assert {:ok, []} = Commands.call("source_list", %{})
    end

    test "normalizes atom-keyed args to strings" do
      assert {:ok, %{name: "n", text: "remember this"} = mem} =
               normalize(Commands.call("memory_remember", %{text: "remember this"}))

      assert mem.text == "remember this"
    end

    test "returns :unknown_command for missing commands" do
      assert {:error, :unknown_command} = Commands.call("nope_nope", %{})
    end
  end

  describe "sources" do
    test "list, create, get, update, delete round trip" do
      assert {:ok, []} = Commands.source_list(%{})

      assert {:ok, source} =
               Commands.source_create(%{"url" => "https://example.com/feed", "type" => "rss"})

      assert {:ok, ^source} = Commands.source_get(%{"id" => source.id})

      assert {:ok, updated} =
               Commands.source_update(%{"id" => source.id, "name" => "Renamed"})

      assert updated.name == "Renamed"

      assert {:ok, _} = Commands.source_delete(%{"id" => source.id})
      assert {:error, :not_found} = Commands.source_get(%{"id" => source.id})
    end

    test "create returns changeset on invalid args" do
      assert {:error, %Ecto.Changeset{}} = Commands.source_create(%{"url" => ""})
    end
  end

  describe "providers" do
    test "create requires api_key for non-ollama" do
      assert {:error, %Ecto.Changeset{}} =
               Commands.provider_create(%{
                 "name" => "anth",
                 "type" => "anthropic",
                 "model" => "claude"
               })
    end

    test "ollama does not require api_key" do
      assert {:ok, provider} =
               Commands.provider_create(%{
                 "name" => "local",
                 "type" => "ollama",
                 "model" => "llama3"
               })

      assert provider.type == "ollama"
    end

    test "active returns nil when no provider is active" do
      assert {:ok, nil} = Commands.provider_active(%{})
    end

    test "set_active flips the active flag" do
      {:ok, p1} =
        Commands.provider_create(%{"name" => "a", "type" => "ollama", "model" => "llama3"})

      assert {:ok, active} = Commands.provider_set_active(%{"id" => p1.id})
      assert active.active == true
      assert {:ok, %{id: id}} = Commands.provider_active(%{})
      assert id == p1.id
    end
  end

  describe "memory" do
    test "remember/list/forget round trip" do
      assert {:ok, mem} = Commands.memory_remember(%{"text" => "hello memory"})
      assert {:ok, [^mem]} = Commands.memory_list(%{})
      assert {:ok, _} = Commands.memory_forget(%{"id" => mem.id})
      assert {:ok, []} = Commands.memory_list(%{})
    end

    test "forget returns :not_found for missing id" do
      assert {:error, :not_found} = Commands.memory_forget(%{"id" => 99_999})
    end
  end

  describe "calendar events" do
    test "create + get + delete" do
      assert {:ok, event} =
               Commands.event_create(%{
                 "event_id" => "ev1",
                 "date" => "2026-06-01",
                 "title" => "Conference"
               })

      assert {:ok, ^event} = Commands.event_get(%{"id" => event.id})
      assert {:ok, _} = Commands.event_delete(%{"id" => event.id})
    end
  end

  describe "documents" do
    test "list returns documents" do
      assert {:ok, list} = Commands.document_list(%{})
      assert is_list(list)
    end

    test "document_read returns :not_found for missing id" do
      assert {:error, :not_found} = Commands.document_read(%{"id" => 99_999})
    end
  end

  describe "google accounts" do
    test "create, list, get, update, delete round trip with safe summaries" do
      assert {:ok, summary} =
               Commands.google_account_create(%{
                 "email" => "me@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret"
               })

      assert summary.email == "me@example.com"
      assert summary.has_client_secret
      refute Map.has_key?(summary, :client_secret)

      assert {:ok, [listed]} = Commands.google_account_list(%{})
      assert listed.id == summary.id
      assert listed.has_client_secret

      assert {:ok, fetched} = Commands.google_account_get(%{"id" => summary.id})
      assert fetched.id == summary.id

      assert {:ok, updated} =
               Commands.google_account_update(%{
                 "id" => summary.id,
                 "enabled" => false,
                 "default_query" => "newer_than:7d"
               })

      assert updated.enabled == false
      assert updated.default_query == "newer_than:7d"

      assert {:ok, deleted} = Commands.google_account_delete(%{"id" => summary.id})
      assert deleted.id == summary.id
      assert {:ok, []} = Commands.google_account_list(%{})
      assert {:error, :not_found} = Commands.google_account_get(%{"id" => summary.id})
    end
  end

  describe "integrations" do
    test "integration_monitoring_brief accepts a provider override" do
      previous_library_root = Application.get_env(:buster_claw, :library_root)

      library_root =
        Path.join(
          System.tmp_dir!(),
          "buster-claw-commands-monitoring-test-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:buster_claw, :library_root, library_root)

      on_exit(fn ->
        if previous_library_root do
          Application.put_env(:buster_claw, :library_root, previous_library_root)
        else
          Application.delete_env(:buster_claw, :library_root)
        end

        File.rm_rf(library_root)
      end)

      Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "override-model"
        assert body =~ "GitHub deploy snapshot"

        Req.Test.json(conn, %{
          choices: [
            %{
              message: %{
                content: "## Executive summary\n\nCommand-generated operations brief."
              }
            }
          ]
        })
      end)

      {:ok, _active_provider} =
        Providers.create_provider(%{
          name: "active-provider",
          type: "openai",
          model: "active-model",
          api_key: "secret",
          active: true
        })

      {:ok, override_provider} =
        Providers.create_provider(%{
          name: "override-provider",
          type: "openai",
          model: "override-model",
          api_key: "secret",
          active: false
        })

      assert {:ok, _document} =
               Library.save_raw_document(%{
                 date: ~D[2026-05-27],
                 filename: "github-deploy-snapshot.md",
                 name: "GitHub deploy snapshot",
                 source_url: "https://github.com/acme/checkout",
                 tags: ["integration", "github", "activity"],
                 content: "# GitHub deploy snapshot\n\nDeploy signal."
               })

      assert {:ok, report} =
               Commands.integration_monitoring_brief(%{
                 "provider_id" => "#{override_provider.id}",
                 "window" => "command smoke"
               })

      assert report.provider_id == override_provider.id
      assert report.model == "override-model"
      assert report.artifact_path =~ "monitoring-brief"
    end
  end

  describe "gmail commands" do
    test "gmail_search uses the default connected Google account" do
      previous = Application.get_env(:buster_claw, :google_req_options)
      previous_library_root = Application.get_env(:buster_claw, :library_root)

      library_root =
        Path.join(
          System.tmp_dir!(),
          "buster-claw-commands-gmail-test-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:buster_claw, :google_req_options,
        plug: {Req.Test, BusterClaw.GoogleHTTP}
      )

      Application.put_env(:buster_claw, :library_root, library_root)

      on_exit(fn ->
        if previous do
          Application.put_env(:buster_claw, :google_req_options, previous)
        else
          Application.delete_env(:buster_claw, :google_req_options)
        end

        if previous_library_root do
          Application.put_env(:buster_claw, :library_root, previous_library_root)
        else
          Application.delete_env(:buster_claw, :library_root)
        end

        File.rm_rf(library_root)
      end)

      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.request_path do
          "/gmail/v1/users/me/messages" ->
            Req.Test.json(conn, %{
              "resultSizeEstimate" => 1,
              "messages" => [%{"id" => "msg-1", "threadId" => "thread-1"}]
            })

          "/gmail/v1/users/me/messages/msg-1" ->
            if conn.query_params["format"] == "full" do
              Req.Test.json(conn, gmail_full_message())
            else
              Req.Test.json(conn, gmail_metadata_message())
            end
        end
      end)

      {:ok, _account} =
        Google.create_account(%{
          "email" => "me@example.com",
          "client_id" => "client-id",
          "client_secret" => "client-secret",
          "refresh_token" => "refresh-token",
          "access_token" => "access-token",
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      assert {:ok, %{messages: [%{id: "msg-1", subject: "Inbox item"}]}} =
               Commands.gmail_search(%{"query" => "in:inbox", "limit" => 1})

      assert {:ok, %{synced: 1, documents: [document]}} =
               Commands.gmail_sync(%{"query" => "in:inbox", "limit" => 1})

      assert document.artifact_path == "raw/2026-05-27/gmail-msg-1.md"
      assert [stored] = Library.list_documents()
      assert stored.id == document.id
    end

    test "gmail_sync incremental mode reports when no history cursor exists" do
      {:ok, _account} =
        Google.create_account(%{
          "email" => "me@example.com",
          "client_id" => "client-id",
          "client_secret" => "client-secret",
          "refresh_token" => "refresh-token",
          "access_token" => "access-token",
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      assert {:ok, %{full_sync_required: true, full_sync_reason: :missing_history_id}} =
               Commands.gmail_sync(%{"incremental" => true})
    end

    test "gmail_draft_create creates a draft for the default connected account" do
      previous = Application.get_env(:buster_claw, :google_req_options)

      Application.put_env(:buster_claw, :google_req_options,
        plug: {Req.Test, BusterClaw.GoogleHTTP}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:buster_claw, :google_req_options, previous)
        else
          Application.delete_env(:buster_claw, :google_req_options)
        end
      end)

      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/gmail/v1/users/me/drafts"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        raw = payload |> get_in(["message", "raw"]) |> decode_base64url!()

        assert raw =~ "To: ada@example.com\r\n"
        assert raw =~ "Subject: Draft from command\r\n"
        assert raw =~ "\r\n\r\nReady for review."

        Req.Test.json(conn, %{
          "id" => "draft-1",
          "message" => %{"id" => "msg-1", "threadId" => "thread-1"}
        })
      end)

      {:ok, _account} =
        Google.create_account(%{
          "email" => "me@example.com",
          "client_id" => "client-id",
          "client_secret" => "client-secret",
          "refresh_token" => "refresh-token",
          "access_token" => "access-token",
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      assert {:ok, %{id: "draft-1", message_id: "msg-1", thread_id: "thread-1"}} =
               Commands.gmail_draft_create(%{
                 "to" => "ada@example.com",
                 "subject" => "Draft from command",
                 "body" => "Ready for review."
               })
    end

    test "gmail_send requires explicit confirmation" do
      assert {:error, :missing_send_confirmation} =
               Commands.gmail_send(%{
                 "to" => "ada@example.com",
                 "subject" => "No confirm",
                 "body" => "Do not send."
               })
    end

    test "gmail_send sends a message for the default connected account" do
      previous = Application.get_env(:buster_claw, :google_req_options)

      Application.put_env(:buster_claw, :google_req_options,
        plug: {Req.Test, BusterClaw.GoogleHTTP}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:buster_claw, :google_req_options, previous)
        else
          Application.delete_env(:buster_claw, :google_req_options)
        end
      end)

      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/gmail/v1/users/me/messages/send"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        raw = payload |> Map.fetch!("raw") |> decode_base64url!()

        assert raw =~ "To: ada@example.com\r\n"
        assert raw =~ "Subject: Send from command\r\n"
        assert raw =~ "\r\n\r\nConfirmed send."

        Req.Test.json(conn, %{
          "id" => "msg-sent-1",
          "threadId" => "thread-sent-1",
          "labelIds" => ["SENT"]
        })
      end)

      {:ok, _account} =
        Google.create_account(%{
          "email" => "me@example.com",
          "client_id" => "client-id",
          "client_secret" => "client-secret",
          "refresh_token" => "refresh-token",
          "access_token" => "access-token",
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      assert {:ok, %{id: "msg-sent-1", thread_id: "thread-sent-1", label_ids: ["SENT"]}} =
               Commands.gmail_send(%{
                 "to" => "ada@example.com",
                 "subject" => "Send from command",
                 "body" => "Confirmed send.",
                 "confirm_send" => true
               })
    end
  end

  describe "google calendar commands" do
    test "google_calendar_sync imports Google events into app calendar" do
      previous = Application.get_env(:buster_claw, :google_req_options)

      Application.put_env(:buster_claw, :google_req_options,
        plug: {Req.Test, BusterClaw.GoogleHTTP}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:buster_claw, :google_req_options, previous)
        else
          Application.delete_env(:buster_claw, :google_req_options)
        end
      end)

      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.request_path == "/calendar/v3/calendars/primary/events"

        Req.Test.json(conn, %{
          "items" => [
            %{
              "id" => "calendar-event-1",
              "status" => "confirmed",
              "summary" => "GWS planning",
              "start" => %{"dateTime" => "2026-05-27T09:30:00-07:00"},
              "end" => %{"dateTime" => "2026-05-27T10:00:00-07:00"}
            }
          ]
        })
      end)

      {:ok, _account} =
        Google.create_account(%{
          "email" => "me@example.com",
          "client_id" => "client-id",
          "client_secret" => "client-secret",
          "refresh_token" => "refresh-token",
          "access_token" => "access-token",
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      assert {:ok, %{imported: 1, created: 1, deleted: 0}} =
               Commands.google_calendar_sync(%{"calendar_id" => "primary", "days_ahead" => 14})

      assert [%{title: "GWS planning", start_time: ~T[09:30:00]}] = AppCalendar.list_events()
    end
  end

  describe "chat" do
    test "chat_send accepts content as a compatibility alias for prompt" do
      assert {:ok, :sent} =
               Commands.chat_send(%{
                 "session_id" => "test-content-alias",
                 "content" => "/help"
               })
    end

    test "chat_send returns a bounded error when prompt is missing" do
      assert {:error, :missing_prompt} = Commands.chat_send(%{"session_id" => "test-missing"})
    end

    test "chat_messages on a fresh session is empty" do
      assert {:ok, messages} = Commands.chat_messages(%{"session_id" => "test-fresh"})
      assert is_list(messages)
    end

    test "chat_clear returns :cleared" do
      assert {:ok, :cleared} = Commands.chat_clear(%{"session_id" => "test-clear"})
    end
  end

  describe "runtime" do
    test "status returns a snapshot map" do
      assert {:ok, snapshot} = Commands.runtime_status(%{})
      assert Map.has_key?(snapshot, :app)
      assert Map.has_key?(snapshot, :phase)
    end
  end

  defp normalize({:ok, %BusterClaw.Memory.Memory{} = memory}),
    do: {:ok, %{name: "n", text: memory.text}}

  defp normalize(other), do: other

  defp representative_commands do
    ~w(
      runtime_status
      source_list
      source_ingest
      provider_active
      document_save
      analysis_queue
      memory_remember
      event_create
      mcp_server_list
      webhook_trigger
      hook_event_execute
      delivery_dispatch_all
      scheduler_job_run_now
      integration_poll_all
      integration_monitoring_brief
      google_account_list
      gmail_search
      gmail_sync
      gmail_draft_create
      gmail_send
      google_calendar_sync
      chat_send
      web_search
      browser_fetch
    )
  end

  defp gmail_metadata_message do
    %{
      "id" => "msg-1",
      "threadId" => "thread-1",
      "historyId" => "history-1",
      "internalDate" => gmail_internal_date_ms(),
      "snippet" => "Inbox snippet.",
      "labelIds" => ["INBOX"],
      "payload" => %{
        "headers" => [
          %{"name" => "Subject", "value" => "Inbox item"},
          %{"name" => "From", "value" => "Ada <ada@example.com>"}
        ]
      }
    }
  end

  defp gmail_full_message do
    gmail_metadata_message()
    |> put_in(["payload", "headers"], [
      %{"name" => "Subject", "value" => "Inbox item"},
      %{"name" => "From", "value" => "Ada <ada@example.com>"},
      %{"name" => "To", "value" => "Luke <luke@example.com>"}
    ])
    |> put_in(["payload", "parts"], [
      %{
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64("Command sync body.", padding: false)}
      }
    ])
  end

  defp gmail_internal_date_ms do
    ~U[2026-05-27 16:00:00Z]
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end

  defp decode_base64url!(data) do
    data
    |> pad_base64()
    |> Base.url_decode64!()
  end

  defp pad_base64(data) do
    case rem(String.length(data), 4) do
      0 -> data
      missing -> data <> String.duplicate("=", 4 - missing)
    end
  end
end
