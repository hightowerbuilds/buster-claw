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

  describe "the harness picker" do
    test "offers every harness plus auto, and marks uninstalled ones", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "— auto —"

      for backend <- BusterClaw.ModelPolicy.backends() do
        assert html =~ Atom.to_string(backend)
      end

      # A harness that is not installed must be visible-but-disabled, not hidden:
      # hiding it makes the app look like it does not support codex at all.
      for backend <- BusterClaw.ModelPolicy.backends(),
          backend not in BusterClaw.AgentBackend.installed() do
        assert html =~ "#{backend} (not installed)"
      end
    end

    # The gap the operator found on 08-04: per-surface rows had a harness picker
    # and the GLOBAL default never did, so the only harness anyone could reach
    # from Settings was whichever one PATH detection happened to pick.
    test "the global harness can be chosen, not just per surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-default-backend-form")
      |> render_change(%{"backend" => "codex"})

      assert BusterClaw.ModelPolicy.backend_for(:default) == :codex
      assert BusterClaw.ModelPolicy.backend_for(:chat) == :codex
    end

    test "the global harness offers all three, and auto", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Global harness"
      assert html =~ "whichever CLI is found"

      for backend <- BusterClaw.ModelPolicy.backends() do
        assert html =~ Atom.to_string(backend)
      end
    end

    # The model list is claude's only while claude is chosen. Offering claude
    # model IDs to an operator running opencode is the one mistake that is
    # unambiguous — opencode needs provider/model.
    test "the model list follows the chosen harness", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert render(view) =~ "claude-opus-5"

      view
      |> element("#model-default-backend-form")
      |> render_change(%{"backend" => "opencode"})

      html = render(view)
      refute html =~ "claude-opus-5"
      assert html =~ "cannot list its own models from here"
      assert html =~ "your opencode CLI decides"
    end

    test "choosing a harness for one surface stores it and leaves others alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-backend-chat")
      |> render_change(%{"surface" => "chat", "backend" => "codex"})

      assert BusterClaw.ModelPolicy.backend_for(:chat) == :codex
      assert BusterClaw.ModelPolicy.backend_for(:dispatcher) == nil
    end

    test "auto gives the choice back to detection", %{conn: conn} do
      {:ok, _} = BusterClaw.ModelPolicy.put_backend(:chat, :codex)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-backend-chat")
      |> render_change(%{"surface" => "chat", "backend" => "auto"})

      assert BusterClaw.ModelPolicy.backend_for(:chat) == nil
    end

    # The money surfaces have no harness picker at all now — offering one would
    # offer a choice whose only outcome is a failed run.
    test "a pinned money surface offers no harness choice, and says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Claude only"
      assert html =~ "which the other harnesses reject"
      refute has_element?(view, "#model-backend-order_submit")
      assert has_element?(view, "#model-backend-chat")
    end

    test "the floor explanation is shown for the money surfaces", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Floor: claude-sonnet-5"
    end
  end

  describe "the agent model picker" do
    test "renders every surface, and says so when nothing is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Agent harness"

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
      assert render(view) =~ "Agent harness"
    end
  end
end
