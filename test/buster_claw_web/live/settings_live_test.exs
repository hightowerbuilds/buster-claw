defmodule BusterClawWeb.SettingsLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.ModelPolicy

  defp secret_key_base,
    do: Application.get_env(:buster_claw, BusterClawWeb.Endpoint)[:secret_key_base]

  test "GET /settings renders the recovery-key panel without exposing the key", %{conn: conn} do
    response = conn |> get(~p"/settings") |> html_response(200)

    assert response =~ "Recovery key"
    assert response =~ "Reveal key"
    # The key itself is hidden until the user reveals it.
    refute response =~ secret_key_base()
  end

  test "revealing the recovery key shows the configured secret", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    refute render(view) =~ secret_key_base()

    html = view |> element("button", "Reveal key") |> render_click()

    assert html =~ secret_key_base()
    assert html =~ "RESTORE_SECRET_KEY"
  end

  describe "the agent model picker" do
    test "renders every surface, and says so when nothing is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Agent models"

      for {_surface, description} <- ModelPolicy.surfaces() do
        # The em-dashed tail is copy; the head is what identifies the row.
        head = description |> String.split(" — ") |> List.first()
        assert html =~ head, "the #{head} surface is missing from the picker"
      end

      # Unset is the shipped state, and it has to read as an answer rather than
      # as a blank — every row should say the CLI is deciding.
      assert html =~ "Your claude CLI decides"
      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
    end

    test "a cheap global default shows the money surfaces held at the floor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#model-default-form", %{"model" => "claude-haiku-4-5"})
        |> render_change()

      in_force = ModelPolicy.in_force()
      assert in_force[:chat].model == "claude-haiku-4-5"
      assert in_force[:chat].source == :default
      assert in_force[:trading_read].model == "claude-sonnet-5"
      assert in_force[:trading_read].source == :floor
      assert in_force[:order_submit].source == :floor

      # The floor is worthless if the operator can't see it bite, and the 07-28
      # reason has to be on the row, not in a tooltip.
      assert html =~ "held at the floor"
      assert html =~ "inventing a financial answer instead of reporting a problem"
    end

    test "a per-surface override moves only that surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#model-default-form", %{"model" => "claude-opus-5"}) |> render_change()

      html =
        view
        |> form("#model-surface-chat", %{"model" => "claude-haiku-4-5"})
        |> render_change()

      in_force = ModelPolicy.in_force()
      assert in_force[:chat].model == "claude-haiku-4-5"
      assert in_force[:chat].source == :surface
      assert in_force[:dispatcher].model == "claude-opus-5"
      assert in_force[:dispatcher].source == :default
      assert in_force[:trading_read].model == "claude-opus-5"
      assert html =~ "set for this surface"
    end

    test "clearing a surface returns it to inheriting the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#model-default-form", %{"model" => "claude-opus-5"}) |> render_change()
      view |> form("#model-surface-chat", %{"model" => "claude-haiku-4-5"}) |> render_change()
      assert ModelPolicy.in_force()[:chat].source == :surface

      html = view |> form("#model-surface-chat", %{"model" => ""}) |> render_change()

      assert ModelPolicy.in_force()[:chat].model == "claude-opus-5"
      assert ModelPolicy.in_force()[:chat].source == :default
      assert html =~ "inherits the global default again"
    end

    test "free text is accepted for a model we do not ship in the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#model-custom-form", %{"target" => "trading_read", "model" => "  my-own-alias  "})
        |> render_submit()

      assert ModelPolicy.for_surface(:trading_read) == "my-own-alias"
      assert ModelPolicy.in_force()[:trading_read].source == :surface
      # An unlisted model still has to render as the selected option, or the row
      # would claim it was inheriting.
      assert html =~ "my-own-alias"
    end

    test "blank free text is refused without taking the LiveView down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#model-default-form", %{"model" => "claude-opus-5"}) |> render_change()

      html =
        view
        |> form("#model-custom-form", %{"target" => "default", "model" => "   "})
        |> render_submit()

      assert html =~ "Type a model name"
      # Blank is not a clear: the default the operator already set survives.
      assert ModelPolicy.for_surface(:chat) == "claude-opus-5"
      assert render(view) =~ "Agent models"
    end
  end
end
