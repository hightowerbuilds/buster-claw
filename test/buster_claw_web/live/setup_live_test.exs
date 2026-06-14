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
end
