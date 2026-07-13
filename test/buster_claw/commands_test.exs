defmodule BusterClaw.CommandsTest do
  use BusterClaw.DataCase

  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Commands
  alias BusterClaw.Commands.Result
  alias BusterClaw.Dispatch
  alias BusterClaw.Google
  alias BusterClaw.Library
  alias BusterClaw.TerminalWorkspace

  setup do
    Req.Test.verify_on_exit!()
    TerminalWorkspace.drain_pending()
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

      assert %{type: :trigger, tier: :safe} =
               Enum.find(catalog, &(&1.name == "terminal_tab_open"))
    end

    test "every command has a unique name" do
      names = Enum.map(Commands.list_commands(), & &1.name)
      assert names == Enum.uniq(names)
    end

    test "every command name matches a function in the module" do
      for %{name: name} <- Commands.list_commands() do
        # to_existing_atom: if the atom doesn't even exist, the function
        # certainly isn't defined — report that as a missing implementation
        # rather than minting an atom (or raising a confusing ArgumentError).
        exported? =
          try do
            function_exported?(Commands, String.to_existing_atom(name), 1)
          rescue
            ArgumentError -> false
          end

        assert exported?, "missing implementation for command #{name}/1"
      end
    end

    test "every command has tier safe or restricted" do
      for %{name: name, tier: tier} <- Commands.list_commands() do
        assert tier in [:safe, :restricted],
               "command #{name} has unexpected tier #{inspect(tier)}"
      end
    end

    test "browser co-presence commands surface as restricted" do
      catalog = Commands.list_commands()
      tier = fn name -> Enum.find(catalog, &(&1.name == name)) end

      assert %{type: :read, tier: :restricted} = tier.("browser_current")
      assert %{type: :trigger, tier: :restricted} = tier.("browser_navigate")
      assert %{type: :trigger, tier: :restricted} = tier.("browser_open_tab")
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

  describe "wallet commands" do
    test "wallet_* tiers: reads safe, writes restricted, delete gated" do
      catalog = Commands.list_commands()
      tier = fn name -> Enum.find(catalog, &(&1.name == name)) end

      assert %{type: :read, tier: :safe} = tier.("wallet_list")
      assert %{type: :read, tier: :safe} = tier.("wallet_list_transactions")
      assert %{type: :mutate, tier: :restricted} = tier.("wallet_create")
      assert %{type: :mutate, tier: :restricted} = tier.("wallet_add_transaction")
      assert %{type: :mutate, tier: :restricted, gated: true} = tier.("wallet_delete")
    end

    test "create, add transaction, and read back through the dispatcher" do
      assert {:ok, wallet} =
               Commands.call("wallet_create", %{"name" => "Acme Ops", "type" => "business"},
                 caller: :trusted
               )

      assert {:ok, _} =
               Commands.call(
                 "wallet_add_transaction",
                 %{
                   "wallet_id" => wallet.id,
                   "kind" => "income",
                   "amount_cents" => 50_000,
                   "occurred_on" => "2026-06-20"
                 },
                 caller: :trusted
               )

      assert {:ok, reread} = Commands.call("wallet_get", %{"id" => wallet.id}, caller: :agent)
      assert reread.balance_cents == 50_000
    end

    test "untrusted callers are blocked from restricted/gated wallet writes" do
      {:ok, wallet} =
        Commands.call("wallet_create", %{"name" => "Acme", "type" => "business"},
          caller: :trusted
        )

      # agent/mcp may not run restricted commands at all
      assert {:error, :requires_confirmation} =
               Commands.call("wallet_create", %{"name" => "X", "type" => "business"},
                 caller: :agent
               )

      # agent_untrusted may mutate, but not fire gated deletes
      assert {:error, :requires_confirmation} =
               Commands.call("wallet_delete", %{"id" => wallet.id}, caller: :agent_untrusted)

      # safe reads are allowed for untrusted callers
      assert {:ok, _} = Commands.call("wallet_list", %{}, caller: :agent)
    end

    test "feed commands: list safe, create restricted, delete gated, poll trigger" do
      catalog = Commands.list_commands()
      entry = fn name -> Enum.find(catalog, &(&1.name == name)) end

      assert %{type: :read, tier: :safe} = entry.("wallet_feed_list")
      assert %{type: :mutate, tier: :restricted} = entry.("wallet_feed_create")
      assert %{type: :mutate, tier: :restricted, gated: true} = entry.("wallet_feed_delete")
      assert %{type: :trigger, tier: :restricted} = entry.("wallet_poll")

      {:ok, wallet} =
        Commands.call("wallet_create", %{"name" => "Feeds", "type" => "business"},
          caller: :trusted
        )

      assert {:ok, feed} =
               Commands.call(
                 "wallet_feed_create",
                 %{
                   "wallet_id" => wallet.id,
                   "kind" => "market",
                   "config" => %{"symbol" => "AAPL"}
                 },
                 caller: :trusted
               )

      assert {:ok, feeds} =
               Commands.call("wallet_feed_list", %{"wallet_id" => wallet.id}, caller: :agent)

      assert length(feeds) == 1

      # wallet_poll with no FINNHUB key configured still succeeds (feed records error)
      assert {:ok, %{results: 1}} =
               Commands.call("wallet_poll", %{"id" => wallet.id}, caller: :trusted)

      assert {:error, :requires_confirmation} =
               Commands.call("wallet_feed_delete", %{"id" => feed.id}, caller: :agent_untrusted)
    end
  end

  describe "call/2 dispatcher" do
    test "dispatches to the matching command" do
      assert {:ok, []} = Commands.call("event_list", %{})
    end

    test "normalizes atom-keyed args to strings" do
      assert {:ok, event} =
               Commands.call("event_create", %{
                 event_id: "e-atom",
                 date: "2026-06-14",
                 title: "remember this"
               })

      assert event.title == "remember this"
    end

    test "returns :unknown_command for missing commands" do
      assert {:error, :unknown_command} = Commands.call("nope_nope", %{})
    end
  end

  describe "call/3 caller enforcement" do
    test "trusted caller (the default) may run restricted commands" do
      assert {:ok, _} =
               Commands.call(
                 "event_create",
                 %{"event_id" => "e-trusted", "date" => "2026-06-14", "title" => "trusted note"},
                 caller: :trusted
               )
    end

    test "untrusted callers may run safe-tier commands" do
      for caller <- [:agent, :mcp] do
        assert {:ok, _} = Commands.call("runtime_status", %{}, caller: caller)
        assert {:ok, []} = Commands.call("event_list", %{}, caller: caller)
      end
    end

    test "untrusted callers are refused restricted commands and cause no side effect" do
      assert {:error, :requires_confirmation} =
               Commands.call(
                 "event_create",
                 %{"event_id" => "e-evil", "date" => "2026-06-14", "title" => "evil note"},
                 caller: :mcp
               )

      assert {:ok, []} = Commands.event_list(%{})
    end

    test "unknown command for an untrusted caller still reports :unknown_command" do
      assert {:error, :unknown_command} = Commands.call("nope_nope", %{}, caller: :mcp)
    end

    test "EVERY restricted command in the catalog is refused for the :mcp caller" do
      for %{name: name, tier: :restricted} <- Commands.list_commands() do
        assert {:error, :requires_confirmation} = Commands.call(name, %{}, caller: :mcp),
               "expected restricted command #{name} to be refused for the :mcp caller"
      end
    end

    test "command_gated?/1 marks the outbound/irreversible commands" do
      for name <-
            ~w(gmail_send document_delete event_delete integration_delete
               gmail_delete gcal_event_delete drive_delete contacts_delete tasks_delete) do
        assert Commands.command_gated?(name), "expected #{name} to be gated"
      end

      # Restricted Workspace writes that are recoverable/non-outbound are NOT gated
      # (an autonomous run may do them without surfacing for approval).
      for name <-
            ~w(gmail_draft_create document_save event_create document_list runtime_status
               gmail_trash drive_upload sheets_update_values docs_batch_update contacts_update) do
        refute Commands.command_gated?(name), "did not expect #{name} to be gated"
      end
    end

    test "new Google Workspace commands carry the expected tiers" do
      for name <- ~w(drive_list drive_get docs_get sheets_get sheets_get_values slides_get
                     contacts_list contacts_search contacts_get tasks_list tasks_get) do
        assert Commands.command_tier(name) == :safe, "expected #{name} to be safe-tier"
      end

      for name <- ~w(drive_upload drive_share docs_create sheets_update_values slides_create
                     contacts_create gcal_event_create gmail_modify tasks_create) do
        assert Commands.command_tier(name) == :restricted, "expected #{name} to be restricted"
      end
    end

    test "drive_share requires its confirm flag before reaching Google" do
      assert {:error, :missing_confirmation} =
               Commands.call(
                 "drive_share",
                 %{"file_id" => "f-1", "role" => "reader", "type" => "anyone"},
                 caller: :trusted
               )
    end

    test ":agent_untrusted runs non-gated restricted commands autonomously" do
      # A draft/save/calendar edit on untrusted-origin work is allowed without
      # asking — only the gated set surfaces for approval.
      assert {:ok, _} =
               Commands.call(
                 "event_create",
                 %{"event_id" => "e-untrusted-ok", "date" => "2026-06-14", "title" => "ok"},
                 caller: :agent_untrusted
               )
    end

    test ":agent_untrusted is refused a gated command and it does NOT execute" do
      {:ok, event} =
        Commands.call(
          "event_create",
          %{"event_id" => "e-keep", "date" => "2026-06-14", "title" => "keep me"},
          caller: :trusted
        )

      assert {:error, :requires_confirmation} =
               Commands.call("event_delete", %{"id" => event.id}, caller: :agent_untrusted)

      # Still there: the gated delete was refused before execution.
      assert {:ok, _} = Commands.call("event_get", %{"id" => event.id})
    end

    test "EVERY gated command is refused for :agent_untrusted" do
      for %{name: name} = entry <- Commands.list_commands(), Map.get(entry, :gated) do
        assert {:error, :requires_confirmation} =
                 Commands.call(name, %{}, caller: :agent_untrusted),
               "expected gated command #{name} to be refused for :agent_untrusted"
      end
    end

    test "a trusted caller bypasses the gate (a gated command reaches dispatch)" do
      # Not refused: it runs and fails on its own terms (no such event), proving
      # the gate does not apply to trusted callers.
      assert {:error, :not_found} =
               Commands.call("event_delete", %{"id" => 999_999}, caller: :trusted)
    end

    test "safe_commands/0 and command_tier/1 agree with the catalog" do
      assert Enum.all?(Commands.safe_commands(), &(&1.tier == :safe))
      assert Commands.command_tier("event_list") == :safe
      assert Commands.command_tier("event_create") == :restricted
      assert Commands.command_tier("nope_nope") == nil
    end

    test "lifted catalog lookups agree with list_commands/0 for every entry" do
      catalog = Commands.list_commands()

      # safe_commands/0 is exactly the safe-tier slice of the catalog.
      assert Commands.safe_commands() == Enum.filter(catalog, &(&1.tier == :safe))

      # The precomputed lookup maps return the same tier/type as the catalog list.
      for %{name: name, tier: tier, type: type} <- catalog do
        assert Commands.command_tier(name) == tier
        assert Commands.command_type(name) == type
      end
    end

    test "command_type/1 returns the catalog type and nil for unknowns" do
      assert Commands.command_type("event_list") == :read
      assert Commands.command_type("event_create") == :mutate
      assert Commands.command_type("web_search") == :trigger
      assert Commands.command_type("nope_nope") == nil
    end
  end

  describe "events (CRUD round trip)" do
    test "create/list/delete round trip" do
      assert {:ok, ev} =
               Commands.event_create(%{
                 "event_id" => "e-rt",
                 "date" => "2026-06-14",
                 "title" => "hello event"
               })

      assert {:ok, listed} = Commands.event_list(%{})
      assert Enum.map(listed, & &1.id) == [ev.id]
      assert {:ok, _} = Commands.event_delete(%{"id" => ev.id})
      assert {:ok, []} = Commands.event_list(%{})
    end

    test "delete returns :not_found for missing id" do
      assert {:error, :not_found} = Commands.event_delete(%{"id" => 99_999})
    end
  end

  describe "shift assignment commands" do
    test "start/status/stop role sessions inside the active shift" do
      assert {:error, :no_active_shift} =
               Commands.shift_assignment_start(%{"role_key" => "mail-triage"})

      assert {:ok, %{shift_id: shift_id}} =
               Commands.shift_start(%{
                 "job" => "lookout",
                 "agent_name" => "Lookout",
                 "shell" => "Primary terminal",
                 "hours" => 12
               })

      assert {:ok, assignment} =
               Commands.shift_assignment_start(%{
                 "role_key" => "mail-triage",
                 "agent_name" => "Mail Triage",
                 "shell" => "Email terminal"
               })

      assert assignment.shift_id == shift_id
      assert assignment.role_key == "mail-triage"
      assert assignment.status == "active"

      assert {:ok, %{active_shift_id: ^shift_id, assignments: [active]}} =
               Commands.shift_assignment_status(%{})

      assert active.id == assignment.id

      assert {:ok, stopped} =
               Commands.shift_assignment_stop(%{"role_key" => "mail-triage"})

      assert stopped.status == "stopped"
      assert {:ok, %{assignments: []}} = Commands.shift_assignment_status(%{})
    end
  end

  describe "unattended shift" do
    test "shift_start defaults to attended; shift_status reflects it" do
      assert {:ok, %{unattended: false}} = Commands.shift_start(%{"job" => "lookout"})
      assert {:ok, %{active: true, unattended: false}} = Commands.shift_status(%{})
    end

    test "shift_start with unattended: true starts an unattended shift" do
      assert {:ok, %{unattended: true}} =
               Commands.shift_start(%{"job" => "dispatcher", "unattended" => true})

      assert {:ok, %{active: true, unattended: true}} = Commands.shift_status(%{})
    end
  end

  describe "activity_report" do
    test "returns a window summary (safe-tier; runs for untrusted callers too)" do
      assert {:ok, report} = Commands.call("activity_report", %{"days" => 30}, caller: :mcp)
      assert report.days == 30

      for key <- [:handled, :blocked, :failed, :open, :runs],
          do: assert(Map.has_key?(report, key))
    end

    test "defaults to a 7-day window" do
      assert {:ok, %{days: 7}} = Commands.call("activity_report", %{}, caller: :trusted)
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

  describe "dispatch reply" do
    setup do
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

      {:ok, _account} =
        Google.create_account(%{
          "email" => "me@example.com",
          "client_id" => "client-id",
          "client_secret" => "client-secret",
          "refresh_token" => "refresh-token",
          "access_token" => "access-token",
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      {:ok, item} =
        Dispatch.enqueue(%{
          source: "gmail",
          source_account: "me@example.com",
          sender: "Ada <ada@example.com>",
          trusted: true,
          trusted_sender: "*@example.com",
          gmail_message_id: "msg-1",
          gmail_thread_id: "thread-1",
          gmail_rfc_message_id: "<original-abc@mail.example.com>",
          subject: "Launch notes",
          recommended_role_key: "mail-triage"
        })

      %{item: item}
    end

    test "sends a threaded reply to the sender and marks the item done", %{item: item} do
      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        assert conn.request_path == "/gmail/v1/users/me/messages/send"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        raw = payload |> Map.fetch!("raw") |> decode_base64url!()

        assert payload["threadId"] == "thread-1"
        assert raw =~ "To: Ada <ada@example.com>\r\n"
        assert raw =~ "Subject: Re: Launch notes\r\n"
        assert raw =~ "In-Reply-To: <original-abc@mail.example.com>\r\n"
        assert raw =~ "References: <original-abc@mail.example.com>\r\n"
        assert raw =~ "\r\n\r\nThanks, will follow up."

        Req.Test.json(conn, %{"id" => "msg-sent-9", "threadId" => "thread-1"})
      end)

      assert {:ok, result} =
               Commands.dispatch_reply(%{"id" => item.id, "body" => "Thanks, will follow up."})

      assert result.dispatch_item_id == item.id
      assert result.status == "done"
      assert result.subject == "Re: Launch notes"
      assert result.thread_id == "thread-1"

      reloaded = Dispatch.get_item!(item.id)
      assert reloaded.status == "done"
      assert reloaded.outcome == "replied"
    end

    test "does not double-prefix an already-Re: subject", %{item: item} do
      {:ok, item} = Dispatch.update_item(item, %{subject: "Re: Launch notes"})

      Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        raw = body |> Jason.decode!() |> Map.fetch!("raw") |> decode_base64url!()
        assert raw =~ "Subject: Re: Launch notes\r\n"
        refute raw =~ "Subject: Re: Re:"
        Req.Test.json(conn, %{"id" => "msg-sent-10", "threadId" => "thread-1"})
      end)

      assert {:ok, _} = Commands.dispatch_reply(%{"id" => item.id, "body" => "ok"})
    end

    test "requires a body", %{item: item} do
      assert {:error, :missing_body} = Commands.dispatch_reply(%{"id" => item.id, "body" => "  "})
      assert Dispatch.get_item!(item.id).status == "queued"
    end

    test "refuses a voicemail item — there is nowhere to send a reply" do
      # `dispatch reply` is a Gmail send. A voicemail item's sender is a phone
      # number and BusterPhone has no outbound channel, so an agent carrying over
      # its mail-triage habit would otherwise hand Gmail "+1503..." as a To:
      # address. Fail loudly instead; the item stays open for a real close-out.
      {:ok, item} =
        Dispatch.enqueue(%{
          source: "voicemail",
          sender: "+15035551234",
          subject: "Voicemail from +15035551234",
          recommended_role_key: "voicemail-triage",
          trusted: true
        })

      assert {:error, :no_reply_channel} =
               Commands.dispatch_reply(%{"id" => item.id, "body" => "calling you back"})

      assert Dispatch.get_item!(item.id).status == "queued"
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

  describe "runtime" do
    test "status returns a snapshot map" do
      assert {:ok, snapshot} = Commands.runtime_status(%{})
      assert Map.has_key?(snapshot, :app)
      assert Map.has_key?(snapshot, :phase)
    end
  end

  describe "terminal workspace commands" do
    test "terminal_tab_open queues a role terminal request" do
      assert {:ok, request} =
               Commands.terminal_tab_open(%{
                 "role_key" => "mail-triage",
                 "label" => "Mail Triage",
                 "session_key" => "mail-triage"
               })

      assert request.role_key == "mail-triage"
      assert request.label == "Mail Triage"
      assert request.session_key == "mail-triage"
      assert request.startup_profile == "mailman"

      assert request.path ==
               "/terminal?session=mail-triage&label=Mail+Triage&startup_profile=mailman"
    end

    test "terminal_tab_open is available to scoped agent callers" do
      assert {:ok, request} =
               Commands.call(
                 "terminal_tab_open",
                 %{"role_key" => "dispatcher", "label" => "Dispatcher"},
                 caller: :mcp
               )

      assert request.role_key == "dispatcher"
      assert request.label == "Dispatcher"
    end
  end

  defp representative_commands do
    ~w(
      runtime_status
      terminal_tab_open
      document_save
      event_create
      integration_poll_all
      google_account_list
      gmail_search
      gmail_sync
      gmail_draft_create
      gmail_send
      google_calendar_sync
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

  describe "browser_download → drive_upload pipeline" do
    test "browser_download is restricted, not gated, and validates its url" do
      assert Commands.command_tier("browser_download") == :restricted
      refute Commands.command_gated?("browser_download")
      assert {:error, :missing_url} = Commands.call("browser_download", %{}, caller: :trusted)
    end

    test "browser_screenshot is restricted (audited) and refused for untrusted callers" do
      assert Commands.command_tier("browser_screenshot") == :restricted
      assert Commands.command_type("browser_screenshot") == :trigger

      assert {:error, :requires_confirmation} =
               Commands.call("browser_screenshot", %{}, caller: :mcp)
    end

    test "browser_download writes the fetched bytes into the workspace downloads folder" do
      tmp = Path.join(System.tmp_dir!(), "bc-dl-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      prev_ws = Application.get_env(:buster_claw, :workspace_root)
      prev_req = Application.get_env(:buster_claw, :browser_req_options)
      Application.put_env(:buster_claw, :workspace_root, tmp)

      Application.put_env(:buster_claw, :browser_req_options,
        plug: {Req.Test, BusterClaw.BrowserHTTP}
      )

      on_exit(fn ->
        restore_env(:workspace_root, prev_ws)
        restore_env(:browser_req_options, prev_req)
        File.rm_rf(tmp)
      end)

      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, <<37, 80, 68, 70>>)
      end)

      assert {:ok, result} =
               Commands.call(
                 "browser_download",
                 %{"url" => "https://example.com/files/report.pdf"},
                 caller: :trusted
               )

      assert result.path =~ ~r"^downloads/\d{4}-\d{2}-\d{2}/report\.pdf$"
      assert result.bytes == 4
      # The file is on disk under the workspace, so drive_upload can read it back.
      assert String.starts_with?(result.absolute_path, tmp)
      assert File.read!(result.absolute_path) == <<37, 80, 68, 70>>
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore_env(key, value), do: Application.put_env(:buster_claw, key, value)
end
