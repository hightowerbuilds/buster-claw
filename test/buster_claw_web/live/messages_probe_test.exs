defmodule BusterClawWeb.MessagesProbeTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:buster_claw, :messages_binary)
    Application.put_env(:buster_claw, :messages_binary, "/missing/messages-test-adapter")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :messages_binary, previous),
        else: Application.delete_env(:buster_claw, :messages_binary)
    end)

    :ok
  end

  test "About offers an explicit check and reports a missing adapter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings?tab=about")
    assert has_element?(view, "#messages-probe-result", "Not checked")
    view |> element("#messages-probe-button") |> render_click()
    render_async(view, 2_000)
    assert has_element?(view, "#messages-probe-result", "missing from this build")
    refute has_element?(view, "#messages-probe-button[disabled]")
  end

  test "adapter readiness is obtained asynchronously without returning private paths", %{
    conn: conn
  } do
    path = Path.join(System.tmp_dir!(), "messages-ui-#{System.unique_integer([:positive])}")

    response =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        result: %{
          version: BusterClaw.Messages.Status.version(),
          protocol_version: 1,
          database: %{ready: true, path: "/private/test-identity/chat.db"},
          methods: ~w(chats.list messages.history watch.subscribe)
        }
      })

    File.write!(path, """
    #!/bin/sh
    IFS= read -r request
    printf '%s\\n' '#{response}'
    while IFS= read -r request; do :; done
    """)

    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:buster_claw, :messages_binary, path)

    {:ok, view, _html} = live(conn, ~p"/settings?tab=about")
    view |> element("#messages-probe-button") |> render_click()
    render_async(view, 2_000)
    assert has_element?(view, "#messages-probe-result", "database access is available")
    assert has_element?(view, "#messages-probe-result", "Sending permission has not been tested")
    refute has_element?(view, "#messages-probe-result", "test-identity")
  end
end
