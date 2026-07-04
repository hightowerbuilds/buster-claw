defmodule BusterClawWeb.HumoLiveTest do
  # async: false — the send test registers the fixed "humo" conv in the global
  # ChatRegistry, and the LiveView subscribes to its PubSub topic.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Transcript

  test "renders the smoke surface with the transcript closed by default", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, BusterClawWeb.HumoLive)

    assert html =~ "humo-surface"
    assert html =~ "data-humo-canvas"
    assert html =~ "Say something into the smoke"
    # The smoke is the primary surface: no open transcript until toggled.
    assert html =~ "show text"
    refute html =~ ~s(id="humo-log")
  end

  test "the text toggle opens the persisted transcript", %{conn: conn} do
    {:ok, _} = Transcript.record("humo", :assistant, "an old reply from the fog")

    {:ok, view, html} = live_isolated(conn, BusterClawWeb.HumoLive)
    refute html =~ "an old reply from the fog"

    html = view |> element("button[phx-click=toggle_text]", "show text") |> render_click()
    assert html =~ ~s(id="humo-log")
    assert html =~ "an old reply from the fog"
  end

  test "sending a message round-trips through the shared engine", %{conn: conn} do
    # Scripted "claude": one assistant block, then a clean exit.
    spawner = fn _prompt, _opts ->
      chat = self()
      port = make_ref()

      spawn(fn ->
        [
          %{"type" => "system", "session_id" => "sess-live"},
          %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "Condensed."}]}
          },
          %{"type" => "result", "result" => "ok", "total_cost_usd" => 0.01, "num_turns" => 1}
        ]
        |> Enum.each(fn map -> send(chat, {port, {:data, Jason.encode!(map) <> "\n"}}) end)

        send(chat, {port, {:exit_status, 0}})
      end)

      {:ok, port}
    end

    {:ok, _pid} =
      Chat.start_link(conv_id: "humo", spawner: spawner, persist: false, audit: false)

    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.HumoLive)

    # Open the text view so the round-trip is visible in the DOM.
    view |> element("button[phx-click=toggle_text]", "show text") |> render_click()

    view
    |> form("form", %{"text" => "hola humo"})
    |> render_submit()

    # The user echo and the scripted reply arrive over PubSub.
    assert render_async_until(view, "hola humo")
    assert render_async_until(view, "Condensed.")
  end

  test "the clear button wipes persisted history even with no live session", %{conn: conn} do
    {:ok, _} = Transcript.record("humo", :user, "olvidame")
    {:ok, _} = Transcript.record("humo", :assistant, "hasta luego")

    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.HumoLive)
    html = view |> element("button[phx-click=toggle_text]", "show text") |> render_click()
    assert html =~ "hasta luego"

    html = view |> element("button[phx-click=clear_chat]", "Clear") |> render_click()

    # DB wiped and the view emptied — no run process was ever registered, so this
    # exercises the local reset path (the {:reset} broadcast never fires here).
    assert BusterClaw.Humo.recent() == []
    refute html =~ "hasta luego"
    refute html =~ ~s(phx-click="clear_chat")
  end

  # The reply arrives over PubSub after the scripted run; poll the rendered
  # HTML briefly instead of racing it.
  defp render_async_until(view, text, attempts \\ 50) do
    cond do
      render(view) =~ text ->
        true

      attempts == 0 ->
        flunk("never rendered: #{text}")

      true ->
        Process.sleep(20)
        render_async_until(view, text, attempts - 1)
    end
  end
end
