defmodule BusterClawWeb.ClawConfirmTest do
  @moduledoc """
  Guards against reintroducing LiveView's native `data-confirm`, which gates the
  event behind `window.confirm()` — a no-op returning false in the Tauri webview,
  so the action silently never fires. Destructive controls must use
  `data-claw-confirm`, serviced by the JS interceptor in `assets/js/lib/claw_confirm.js`.
  """
  use ExUnit.Case, async: true

  @web_dir Path.expand("../../lib/buster_claw_web", __DIR__)

  test "no template uses the native data-confirm gate" do
    offenders =
      @web_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn file ->
        file |> File.read!() |> String.contains?("data-confirm=")
      end)

    assert offenders == [],
           """
           These templates still use `data-confirm=`, which does nothing in the
           webview (window.confirm returns false). Switch to `data-claw-confirm=`:

           #{Enum.map_join(offenders, "\n", &"  - #{Path.relative_to(&1, File.cwd!())}")}
           """
  end

  test "the confirm interceptor is installed at app boot" do
    app_js = Path.join(@web_dir, "../../assets/js/app.js") |> Path.expand()
    assert File.read!(app_js) =~ "installClawConfirm()"
  end
end
