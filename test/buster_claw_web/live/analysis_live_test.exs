defmodule BusterClawWeb.AnalysisLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.{Library, Providers}
  alias BusterClawWeb.AnalysisLive

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-analysis-live-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)
    Req.Test.verify_on_exit!()

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "queues and runs analysis from the LiveView", %{conn: conn} do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{
        choices: [
          %{message: %{content: "## Summary\n\nLive analysis report."}}
        ]
      })
    end)

    {:ok, _provider} =
      Providers.create_provider(%{
        name: "openai",
        type: "openai",
        model: "gpt-5.4",
        active: true
      })

    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "live-analysis.md",
               name: "Live Analysis",
               content: "# Live Analysis\n\nAnalyze me."
             })

    {:ok, view, html} = live_isolated(conn, AnalysisLive)

    assert html =~ "Analysis Queue"
    assert html =~ "Live Analysis"
    assert html =~ "No analysis jobs yet"

    html =
      view
      |> element("button[phx-value-id='#{document.id}']", "Queue")
      |> render_click()

    assert html =~ "queued"
    assert html =~ "1"

    html = render_click(view, "run_pending")

    assert html =~ "done"
    assert html =~ "analysis-"
    assert html =~ "gpt-5.4"
  end
end
