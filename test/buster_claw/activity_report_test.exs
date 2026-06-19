defmodule BusterClaw.ActivityReportTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.ActivityReport
  alias BusterClaw.Dispatch.Item
  alias BusterClaw.Repo
  alias BusterClaw.Sentinel

  @now ~U[2026-06-18 12:00:00Z]

  defp item!(attrs) do
    %Item{}
    |> Item.changeset(
      Map.merge(
        %{
          source: "gmail",
          status: "queued",
          dedupe_key: "k#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "counts finished items by status within the window" do
    # In-window (3 days ago)
    recent = DateTime.add(@now, -3 * 86_400, :second)
    item!(%{status: "done", finished_at: recent})
    item!(%{status: "done", finished_at: recent})
    item!(%{status: "blocked", finished_at: recent})
    item!(%{status: "failed", finished_at: recent})
    # Out of window (30 days ago)
    old = DateTime.add(@now, -30 * 86_400, :second)
    item!(%{status: "done", finished_at: old})

    report = ActivityReport.summary(now: @now, days: 7)

    assert report.handled == 2
    assert report.blocked == 1
    assert report.failed == 1
    assert report.days == 7
  end

  test "counts currently-open items regardless of the window" do
    item!(%{status: "queued"})
    item!(%{status: "claimed"})
    item!(%{status: "running"})
    item!(%{status: "done", finished_at: DateTime.add(@now, -1 * 86_400, :second)})

    report = ActivityReport.summary(now: @now)

    assert report.open == 3
  end

  test "counts unattended agent runs recorded in the window" do
    Sentinel.observe(:command_invoke, "Unattended agent run completed", %{shift_id: 1})
    Sentinel.observe(:command_invoke, "Unattended agent run failed", %{shift_id: 1})
    # A non-run command_invoke is not counted.
    Sentinel.observe(:command_invoke, "event_create (ok)", %{})

    report = ActivityReport.summary(now: DateTime.utc_now())

    assert report.runs == 2
  end

  test "empty history yields zeros" do
    report = ActivityReport.summary(now: @now)
    assert report.handled == 0
    assert report.blocked == 0
    assert report.failed == 0
    assert report.open == 0
    assert report.runs == 0
  end
end
