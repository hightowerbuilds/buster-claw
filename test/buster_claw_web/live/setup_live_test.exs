defmodule BusterClawWeb.SetupLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Google
  alias BusterClaw.Settings
  alias BusterClaw.Setup

  test "intro step renders the explainer", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")
    assert html =~ "How Buster Claw works"
    assert html =~ "First-run setup"
  end

  test "Get started advances to the identity step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    html = view |> element("button", "Get started") |> render_click()
    assert html =~ "using Buster Claw?"
  end

  test "saving a profile name marks the identity step complete", %{conn: conn} do
    refute Setup.profile_complete?()

    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "goto", %{"step" => "identity"})
    render_hook(view, "save_profile", %{"name" => "Ada Lovelace", "org" => ""})

    assert Setup.profile_complete?()
    assert Settings.get("profile_name") == "Ada Lovelace"
  end

  test "confirm_workspace marks the workspace step complete", %{conn: conn} do
    refute Setup.workspace_complete?()

    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "goto", %{"step" => "workspace"})
    render_hook(view, "confirm_workspace", %{})

    assert Setup.workspace_complete?()
  end

  test "done step shows the completion checklist and Finish redirects home", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    html = render_hook(view, "goto", %{"step" => "done"})
    assert html =~ "of 3 steps complete"

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("button", "Finish setup") |> render_click()
  end

  describe "home setup CTA" do
    test "shows progress while incomplete and hides once every step is done", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Set up Buster Claw"

      # Complete two of three steps.
      Setup.put_profile("Ada", "")
      Setup.confirm_workspace()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "2 of 3 complete"

      # Complete the remaining step via real state.
      {:ok, _} =
        Google.upsert_account(%{"email" => "a@b.com", "client_id" => "cid", "enabled" => true})

      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "Set up Buster Claw"
      refute html =~ "Finish setup"
    end
  end
end
