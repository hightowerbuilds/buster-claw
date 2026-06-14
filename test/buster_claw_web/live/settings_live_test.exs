defmodule BusterClawWeb.SettingsLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
end
