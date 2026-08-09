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

    # A terminal run used to pin the tab in Agent Mode forever: the banner took
    # the newest registered run unconditionally, runs stay registered after they
    # end, and every control hides itself once terminal — a dead end with no way
    # out but a restart.
    test "a finished run can be dismissed, and never outranks a live one", %{conn: conn} do
      done = start_run()
      {:ok, view, _html} = live(conn, "/browse")

      html = render_click(view, "agent_stop", %{})
      assert html =~ "STOPPED"

      html = render_click(view, "agent_dismiss", %{})
      refute html =~ "agent-mode-banner"
      # Dismissing is a view concern — the trajectory is still there to inspect.
      assert AgentMode.mode(done) == :stopped

      # And a live run always wins over a terminal one, dismissed or not.
      live_run = start_run()
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "agent-mode-banner"
      assert html =~ "AGENT WORKING"
      assert AgentMode.mode(live_run) == :agent_working
    end

    # THE SECOND-RUN TRAP. `agent_dismissed` held ONE run_id, and runs stay
    # registered after they end — so with two finished runs, dismissing the
    # newest revealed the older one, and dismissing THAT one revealed the newest
    # again, because the single slot had just been overwritten. The banner
    # alternated forever and the native browser surface (`:if={!@agent_run}`)
    # never came back: the tab was stuck in Agent Mode permanently, for every
    # operator who ran an errand twice.
    test "every finished run can be dismissed, not just the newest", %{conn: conn} do
      first = start_run()
      {:ok, view, _html} = live(conn, "/browse")
      render_click(view, "agent_stop", %{})

      second = start_run()
      _ = :sys.get_state(view.pid)
      render_click(view, "agent_stop", %{})

      assert AgentMode.mode(first) == :stopped
      assert AgentMode.mode(second) == :stopped

      # Two dismissals for two finished runs, and the tab is a browser again.
      render_click(view, "agent_dismiss", %{})
      html = render_click(view, "agent_dismiss", %{})

      refute html =~ "agent-mode-banner",
             "a second finished run re-pinned the tab — dismissal is not accumulating"

      assert html =~ "data-browser-surface",
             "the native browser surface never came back"
    end

    # The other half of "stuck in Agent Mode": the surface itself. The mirror is
    # an MJPEG stream from the run's Chromium, so once the run ends it is a dead
    # frame — but it held the surface slot for ANY registered run, live or not,
    # and the native webview stayed hidden behind it (`data-agent-mirror`). So
    # every completed errand left the operator looking at a frozen picture of a
    # closed browser until they found Dismiss. Ending the run is the restore.
    test "a finished run gives the browser back without waiting to be dismissed", %{conn: conn} do
      start_run()
      {:ok, view, html} = live(conn, "/browse")

      # While live: the mirror owns the surface and the webview is hidden.
      assert html =~ ~s(data-agent-mirror="1")
      refute html =~ "data-browser-surface"

      html = render_click(view, "agent_stop", %{})

      # The outcome is still on screen — that part must not vanish.
      assert html =~ "agent-mode-banner"
      assert html =~ "STOPPED"

      # …but the browser is a browser again, with no click required.
      refute html =~ ~s(data-agent-mirror="1")

      assert html =~ "data-browser-surface",
             "a finished run still held the surface — the operator is stuck on a dead mirror"
    end

    test "the human can mark a handoff done without resuming the agent", %{conn: conn} do
      pid = start_run(true)
      {:ok, view, _html} = live(conn, "/browse")

      {:handoff, :payment, _meta} = AgentMode.navigate(pid, "https://shop.com/checkout")
      _ = :sys.get_state(view.pid)

      # Stop was the only exit from a handoff, so an errand the human finished
      # themselves got recorded as halted.
      html = render_click(view, "agent_finish", %{})
      assert html =~ "DONE"
      assert AgentMode.mode(pid) == :done
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
