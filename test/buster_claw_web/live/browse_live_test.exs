defmodule BusterClawWeb.BrowseLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  # /browse is now an embedded-webview shell: the live page renders the toolbar +
  # surface + fallback, and the native webview / navigation is driven client-side
  # by the EmbeddedBrowser hook (only in the desktop app). Server-side coverage is
  # the rendered shell + the deep-link seeding the address bar.

  test "renders the browser shell surface + fallback (chrome is native)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse")

    # Solo /browse is the "main" native browser surface.
    assert html =~ ~s(id="browse-shell-main")
    assert html =~ ~s(data-surface-id="main")
    assert html =~ ~s(phx-hook="EmbeddedBrowser")
    assert html =~ "data-browser-surface"
    # Fallback notice (revealed client-side outside the desktop app).
    assert html =~ "desktop app"
  end

  test "a ?url= deep link seeds the address bar and hook", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse?url=https://example.com")

    assert html =~ ~s(data-initial-url="https://example.com")
  end

  test "a new tab (?t=) opens blank", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse?t=abc123")

    assert html =~ ~s(id="browse-shell-main")
    refute html =~ ~s(data-initial-url="https)
  end

  describe "agent-workspace mode" do
    alias BusterClaw.BrowserControl.{AgentMode, Scope}
    alias BusterClaw.BrowserControl.Commerce.Cart

    # Scripted scope-gate: /checkout is a payment page, everything on-scope ok.
    defmodule StubNav do
      def navigate(_session, %Scope{} = scope, url, _opts \\ []) do
        if String.contains?(url, "checkout") do
          {:halt, :payment_stop, %{url: url, host: "shop.com"}}
        else
          {:ok, %{scope_id: scope.id, host: "shop.com", url: url}}
        end
      end
    end

    # No command/3 — capture degrades, which is not what these tests are about.
    defmodule NoCaptureSession do
    end

    defp start_run(commerce? \\ false) do
      scope =
        Scope.new("buy office supplies", ["shop.com"],
          id: "ui-#{System.unique_integer([:positive])}"
        )

      {:ok, pid} =
        AgentMode.start_link(
          scope: scope,
          session: :stub,
          session_mod: NoCaptureSession,
          navigate_mod: StubNav,
          clock: fn -> 0 end,
          on_payment: if(commerce?, do: :handoff, else: :halt)
        )

      {:ok, :agent_working} = AgentMode.start_run(pid)
      pid
    end

    test "no run: the tab is a plain browser", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/browse")

      refute html =~ "agent-mode-banner"
      refute html =~ "agent-mode-rail"
    end

    test "an active run switches the tab: banner, mode, live trajectory", %{conn: conn} do
      pid = start_run()
      {:ok, view, html} = live(conn, "/browse")

      assert html =~ "agent-mode-banner"
      assert html =~ "AGENT WORKING"
      assert html =~ "agent-mode-rail"

      # A step lands and the rail updates live off the broadcast.
      {:ok, _} = AgentMode.navigate(pid, "https://shop.com/products")
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "navigate https://shop.com/products"

      # Stop from the banner: the run halts before its next action.
      html = render_click(view, "agent_stop", %{})
      assert html =~ "STOPPED"
      assert AgentMode.mode(pid) == :stopped
    end

    test "the payment handoff shows the cart card and confirmation finishes the run", %{
      conn: conn
    } do
      pid = start_run(true)
      {:ok, cart} = Cart.add_item(Cart.new(), "Stapler", 899)
      {:ok, _} = AgentMode.put_cart(pid, cart)

      {:ok, view, _html} = live(conn, "/browse")

      {:handoff, :payment, _meta} = AgentMode.navigate(pid, "https://shop.com/checkout")
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "AWAITING HUMAN"
      assert html =~ "agent-handoff-card"
      assert html =~ "$8.99"

      html =
        view
        |> form("#agent-confirm-purchase-form", %{"confirmation" => "ORDER-9"})
        |> render_submit()

      assert html =~ "Purchase confirmed"
      assert html =~ "DONE"
      assert AgentMode.mode(pid) == :done
    end

    test "take the wheel and resume round-trip from the banner", %{conn: conn} do
      pid = start_run()
      {:ok, view, _html} = live(conn, "/browse")

      html = render_click(view, "agent_take_wheel", %{})
      assert html =~ "AWAITING HUMAN"

      html = render_click(view, "agent_resume", %{})
      assert html =~ "AGENT WORKING"
      assert AgentMode.mode(pid) == :agent_working
    end
  end
end
