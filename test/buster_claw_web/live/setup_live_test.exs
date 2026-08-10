defmodule BusterClawWeb.SetupLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Google
  alias BusterClaw.Settings
  alias BusterClaw.Setup
  alias BusterClaw.TrustedSenders

  test "welcome step renders the explainer", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")
    assert html =~ "Getting started"
    assert html =~ "reachable by email"
  end

  test "Get started advances to the workspace step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    html = view |> element("button", "Get started") |> render_click()
    assert html =~ "Pick your folder"
  end

  test "confirm_workspace marks the workspace step complete", %{conn: conn} do
    refute Setup.workspace_complete?()

    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "goto", %{"step" => "workspace"})
    render_hook(view, "confirm_workspace", %{})

    assert Setup.workspace_complete?()
  end

  test "connecting Google trusts the account's own address", %{conn: conn} do
    refute Setup.google_complete?()

    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "goto", %{"step" => "google"})

    render_hook(view, "connect_google", %{
      "google_account" => %{"email" => "owner@example.com", "client_id" => "cid"}
    })

    assert Setup.google_complete?()
    assert TrustedSenders.trusted?("owner@example.com")
  end

  test "going live marks the live step + onboarding complete and opens the terminal", %{
    conn: conn
  } do
    refute Setup.live_complete?()

    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "goto", %{"step" => "live"})

    assert {:error, {:live_redirect, %{to: "/terminal"}}} =
             view |> element("button", "Open terminal") |> render_click()

    assert Setup.live_complete?()
    assert Settings.onboarding_completed?()
  end

  test "skip for now marks onboarding complete and redirects home", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("button", "Skip for now") |> render_click()

    assert Settings.onboarding_completed?()
  end

  describe "first-run gate" do
    setup do
      Application.put_env(:buster_claw, :onboarding_gate, true)
      on_exit(fn -> Application.put_env(:buster_claw, :onboarding_gate, false) end)
      :ok
    end

    test "home redirects to /setup until onboarding is complete", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/setup"}}} = live(conn, ~p"/")

      Settings.mark_onboarding_complete()
      assert {:ok, _view, _html} = live(conn, ~p"/")
    end
  end

  describe "home setup CTA" do
    test "shows the finish-setup nudge while steps remain", %{conn: conn} do
      # Skipped onboarding: flag is set (so home is reachable) but steps aren't
      # all done, so the home screen keeps nudging.
      Settings.mark_onboarding_complete()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Finish setup" or html =~ "Set up Buster Claw"

      # Connecting Google moves the needle without erroring.
      {:ok, _} =
        Google.upsert_account(%{"email" => "a@b.com", "client_id" => "cid", "enabled" => true})

      assert Setup.google_complete?()
    end
  end

  # The wizard told the user two different things about the same step: three copy
  # strings promised "you'll do this once" while a fourth warned about reconnecting
  # weekly. While Google has the app in "Testing", the weekly one is the true one —
  # so onboarding's cheerful version was a promise it breaks on day eight, made to
  # exactly the people being handed a trial build.
  #
  # These assert the CONTRADICTION cannot come back, not merely that some sentence
  # renders: any onboarding copy claiming a one-time connect while `beta_testing?/0`
  # holds is a regression, wherever a future edit puts it.
  describe "how often the user is told to reconnect Google" do
    setup do
      prev_status = Application.get_env(:buster_claw, :google_oauth_app_status)
      prev_client = Application.get_env(:buster_claw, :google_bundled_client)

      # The beta note is gated on `@bundled_available` — correctly, since the
      # tester list belongs to OUR bundled OAuth app and a bring-your-own-client
      # user has their own. Without a bundled client configured the note never
      # renders, so a test asserting its copy would pass vacuously against an
      # empty string. Configure one.
      Application.put_env(:buster_claw, :google_bundled_client, %{
        client_id: "test-id",
        client_secret: "test-secret"
      })

      BusterClaw.Google.BundledClient.reset()

      on_exit(fn ->
        Application.put_env(:buster_claw, :google_oauth_app_status, prev_status)
        Application.put_env(:buster_claw, :google_bundled_client, prev_client)
        BusterClaw.Google.BundledClient.reset()
      end)

      :ok
    end

    test "while unverified, no onboarding copy promises a one-time connect", %{conn: conn} do
      Application.put_env(:buster_claw, :google_oauth_app_status, "testing")

      {:ok, view, _html} = live(conn, ~p"/setup")
      html = render_hook(view, "goto", %{"step" => "google"})

      assert html =~ "reconnect about once a week"

      # Every phrasing of the broken promise, not just the one that was there.
      refute html =~ "do this once"
      refute html =~ "one-time"
      refute html =~ "one time"
    end

    test "once Google verifies the app, the one-time promise becomes true and returns",
         %{conn: conn} do
      Application.put_env(:buster_claw, :google_oauth_app_status, "verified")

      {:ok, view, _html} = live(conn, ~p"/setup")
      html = render_hook(view, "goto", %{"step" => "google"})

      # `You'll` renders as `You&#39;ll`, so match the part that survives escaping.
      assert html =~ "do this once."
      refute html =~ "reconnect about once a week"
    end

    # An address that is not on Google's tester list never reaches our callback —
    # Google ends the flow on its own "Access blocked" page. The app therefore cannot
    # detect, log, or report this, and the wizard simply sits on step 3 looking broken.
    # Naming the symptom in advance is the only defence available, so it is asserted.
    test "the unverified-app note names the symptom of not being on the tester list",
         %{conn: conn} do
      Application.put_env(:buster_claw, :google_oauth_app_status, "testing")

      {:ok, view, _html} = live(conn, ~p"/setup")
      html = render_hook(view, "goto", %{"step" => "google"})

      assert html =~ "Access blocked"
      assert html =~ "has not completed"
      assert html =~ "isn&#39;t on the list yet"
      # And a way to act on it, not just a diagnosis.
      assert html =~ "Request access"
      assert html =~ "mailto:"
    end

    test "once verified, the tester-list note disappears with the cap it describes",
         %{conn: conn} do
      Application.put_env(:buster_claw, :google_oauth_app_status, "verified")

      {:ok, view, _html} = live(conn, ~p"/setup")
      html = render_hook(view, "goto", %{"step" => "google"})

      refute html =~ "Access blocked"
      refute html =~ "approved-tester list"
    end

    test "the sentence is derived from app status, so call sites cannot drift apart" do
      Application.put_env(:buster_claw, :google_oauth_app_status, "testing")
      assert BusterClawWeb.GoogleOAuth.reconnect_sentence() =~ "once a week"

      Application.put_env(:buster_claw, :google_oauth_app_status, "verified")
      assert BusterClawWeb.GoogleOAuth.reconnect_sentence() == "You'll do this once."
    end
  end

end
