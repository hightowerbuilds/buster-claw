defmodule BusterClawWeb.SettingsModelsTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.AgentBackend
  alias BusterClaw.ModelPolicy

  test "current Claude models can be selected and reach the runner arguments", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    for model <- [
          "claude-opus-5-5",
          "claude-sonnet-5-5",
          "claude-haiku-5-5",
          "claude-fable-5-1"
        ] do
      assert has_element?(view, "#model-default-form option[value='#{model}']")
      view |> form("#model-default-form", %{"model" => model}) |> render_change()

      assert ModelPolicy.for_surface(:chat) == model
      assert has_element?(view, "#model-default-form option[value='#{model}'][selected]")

      argv = AgentBackend.argv(:claude, "hello", model: ModelPolicy.for_surface(:chat))
      assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.member?(["--model", model])
    end
  end

  test "current Codex models can be selected without changing Claude defaults", %{conn: conn} do
    {:ok, _} = ModelPolicy.put_model(:claude, :default, "claude-sonnet-5-5")
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#model-default-backend-form") |> render_change(%{"backend" => "codex"})

    for model <- ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol"] do
      assert has_element?(view, "#model-default-form option[value='#{model}']")
      view |> form("#model-default-form", %{"model" => model}) |> render_change()

      assert ModelPolicy.for_surface(:chat) == model
      assert ModelPolicy.model_for(:claude, :default) == "claude-sonnet-5-5"

      argv = AgentBackend.argv(:codex, "hello", model: ModelPolicy.for_surface(:chat))
      assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.member?(["--model", model])
    end

    {:ok, reloaded, _html} = live(conn, ~p"/settings")
    assert has_element?(reloaded, "#model-default-form option[value='gpt-6-sol'][selected]")
  end

  test "chat's model choices follow its own harness and survive switching back", %{conn: conn} do
    {:ok, _} = ModelPolicy.put_model(:claude, :default, "claude-sonnet-5-5")
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> element("#model-backend-chat")
    |> render_change(%{"surface" => "chat", "backend" => "codex"})

    assert has_element?(view, "#model-surface-chat option[value='gpt-6.1-sol']")
    refute has_element?(view, "#model-surface-chat option[value='claude-sonnet-5-5']")
    assert has_element?(view, "#model-surface-dispatcher option[value='claude-sonnet-5-5']")
    refute has_element?(view, "#model-surface-dispatcher option[value='gpt-6.1-sol']")

    view |> form("#model-surface-chat", %{"model" => "gpt-6.1-sol"}) |> render_change()

    view
    |> element("#model-backend-chat")
    |> render_change(%{"surface" => "chat", "backend" => "claude"})

    view |> form("#model-surface-chat", %{"model" => "claude-haiku-5-5"}) |> render_change()

    view
    |> element("#model-backend-chat")
    |> render_change(%{"surface" => "chat", "backend" => "codex"})

    assert has_element?(view, "#model-surface-chat option[value='gpt-6.1-sol'][selected]")
    assert ModelPolicy.for_surface(:chat) == "gpt-6.1-sol"
    assert ModelPolicy.model_for(:claude, :chat) == "claude-haiku-5-5"
    assert ModelPolicy.for_surface(:dispatcher) == "claude-sonnet-5-5"
  end

  test "a Claude override offers Claude models under a Codex global harness", %{conn: conn} do
    {:ok, _} = ModelPolicy.put_backend(:default, :codex)
    {:ok, _} = ModelPolicy.put_backend(:chat, :claude)
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#model-default-form option[value='gpt-6-astra']")
    assert has_element?(view, "#model-surface-chat option[value='claude-opus-5-5']")
    refute has_element?(view, "#model-surface-chat option[value='gpt-6-astra']")

    view |> form("#model-surface-chat", %{"model" => "claude-opus-5-5"}) |> render_change()
    assert ModelPolicy.for_surface(:chat) == "claude-opus-5-5"
  end
end
