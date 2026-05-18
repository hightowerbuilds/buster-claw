defmodule BusterClaw.ChatTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Chat, Integrations, Library, Memory, Providers}

  setup do
    session_id = "test-#{System.unique_integer([:positive])}"
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-chat-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    %{session_id: session_id}
  end

  test "stores user and assistant messages through a provider", %{session_id: session_id} do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{message: %{content: "hello from provider"}})
    end)

    {:ok, provider} =
      Providers.create_provider(%{name: "ollama", type: "ollama", model: "llama3"})

    {:ok, _} = Providers.set_active_provider(provider)
    {:ok, session_pid} = Chat.ensure_session(session_id)
    Req.Test.allow(BusterClaw.ProviderHTTP, self(), session_pid)

    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))
    Chat.send_message(session_id, "hello")

    assert_receive {:message, %{message: %{role: "user", content: "hello"}}}, 500
    assert_receive {:waiting, %{}}, 500
    assert_receive {:token, %{chunk: "hello from provider"}}, 500
    assert_receive {:done, %{content: "hello from provider"}}, 500

    assert [
             %{role: "user", content: "hello"},
             %{role: "assistant", content: "hello from provider"}
           ] = Chat.messages(session_id)
  end

  test "supports memory slash commands", %{session_id: session_id} do
    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    Chat.send_message(session_id, "/remember SQLite owns structured state")
    assert_receive {:done, %{content: "Remembered: SQLite owns structured state"}}, 500
    assert [%{text: "SQLite owns structured state"}] = Memory.list_memories()

    Chat.send_message(session_id, "/memories")
    assert_receive {:done, %{content: content}}, 500
    assert content =~ "SQLite owns structured state"

    Chat.send_message(session_id, "/forget 1")
    assert_receive {:done, %{content: "Forgot memory #1."}}, 500
    assert [] = Memory.list_memories()
  end

  test "clear command resets session messages", %{session_id: session_id} do
    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    Chat.send_message(session_id, "/help")
    assert_receive {:done, _payload}, 500
    assert Chat.messages(session_id) != []

    Chat.send_message(session_id, "/clear")
    assert_receive {:cleared, %{}}, 500
    assert [] = Chat.messages(session_id)
  end

  test "search command returns visible assistant results", %{session_id: session_id} do
    Req.Test.stub(BusterClaw.SearchHTTP, fn conn ->
      Req.Test.html(conn, """
      <div class="result">
        <a class="result__a" href="https://example.com/search">Search Result</a>
        <div class="result__snippet">Search snippet.</div>
      </div>
      """)
    end)

    {:ok, session_pid} = Chat.ensure_session(session_id)
    Req.Test.allow(BusterClaw.SearchHTTP, self(), session_pid)
    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    Chat.send_message(session_id, "/search local ai")

    assert_receive {:done, %{content: content}}, 500
    assert content =~ "Search Results"
    assert content =~ "Search Result"
    assert content =~ "https://example.com/search"
  end

  test "browse command returns a visible fetched page excerpt", %{session_id: session_id} do
    Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
      Req.Test.html(
        conn,
        "<html><head><title>Page</title></head><body><p>Rendered content</p></body></html>"
      )
    end)

    {:ok, session_pid} = Chat.ensure_session(session_id)
    Req.Test.allow(BusterClaw.BrowserHTTP, self(), session_pid)
    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    Chat.send_message(session_id, "/browse https://example.com")

    assert_receive {:done, %{content: content}}, 500
    assert content =~ "Browser Fetch"
    assert content =~ "Rendered content"
  end

  test "integration commands list and poll configured integrations", %{session_id: session_id} do
    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "sentry-prod",
        service_type: "sentry",
        config_text: ~s({"org":"acme"})
      })

    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    Chat.send_message(session_id, "/integrations")
    assert_receive {:done, %{content: content}}, 500
    assert content =~ "sentry-prod"
    assert content =~ "sentry"

    Chat.send_message(session_id, "/poll sentry-prod")
    assert_receive {:done, %{content: content}}, 500
    assert content =~ "Poll failed for sentry-prod"
    assert content =~ "missing_config"
  end

  test "brief command generates a monitoring brief", %{session_id: session_id} do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Operational Snapshot"

      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Executive summary\n\nChat-generated operations brief."
            }
          }
        ]
      })
    end)

    {:ok, provider} =
      Providers.create_provider(%{
        name: "openai",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret",
        active: true
      })

    raw_document!("Operational Snapshot")

    {:ok, session_pid} = Chat.ensure_session(session_id)
    {:ok, _provider} = Providers.set_active_provider(provider)
    assert Providers.active_provider().id == provider.id
    Req.Test.allow(BusterClaw.ProviderHTTP, self(), session_pid)
    :ok = Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    Chat.send_message(session_id, "/brief")

    assert_receive {:done, %{content: content}}, 500
    assert content =~ "Monitoring brief generated"
    assert [report] = Library.list_reports()
    assert report.artifact_path =~ "monitoring-brief"
  end

  defp raw_document!(name) do
    filename =
      name
      |> String.downcase()
      |> String.replace(" ", "-")
      |> Kernel.<>(".md")

    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-18],
               filename: filename,
               name: name,
               source_url: "https://example.com/#{filename}",
               tags: ["integration", "github", "activity"],
               content: "# #{name}\n\nImportant chat source material."
             })

    document
  end
end
