defmodule BusterClaw.ActivityReport do
  @moduledoc """
  The "what your agent did" summary (always-on roadmap, Phase 4c).

  Aggregates the work Buster Claw handled over a recent window from data that
  already exists — the durable Dispatch queue (work units) and the Sentinel feed
  (unattended runs) — into a small map for the operator. This is the report that
  justifies the tool to whoever pays: requests handled, what's blocked, what's
  still open.

  Built on clean indexed columns (`dispatch_items.status` / `finished_at`,
  `security_events.category` / `inserted_at`), so it stays cheap as history grows.
  """

  import Ecto.Query

  alias BusterClaw.Dispatch.Item
  alias BusterClaw.Repo
  alias BusterClaw.Sentinel.Event

  @default_days 7
  @open_statuses ~w(queued claimed running)
  @run_message_prefix "Unattended agent run"

  @doc """
  Summary over the last `:days` days (default #{@default_days}).

  `:now` may be supplied for deterministic windows (tests); defaults to the
  current UTC time. Returns:

      %{
        days:    integer,
        since:   DateTime, until: DateTime,
        handled: non_neg_integer,   # items finished "done" in the window
        blocked: non_neg_integer,   # items finished "blocked" in the window
        failed:  non_neg_integer,   # items finished "failed" in the window
        open:    non_neg_integer,   # items currently open (queued/claimed/running)
        runs:    non_neg_integer    # unattended agent runs recorded in the window
      }
  """
  def summary(opts \\ []) do
    days = Keyword.get(opts, :days, @default_days)
    now = (Keyword.get(opts, :now) || DateTime.utc_now()) |> DateTime.truncate(:second)
    since = DateTime.add(now, -days * 86_400, :second)

    %{
      days: days,
      since: since,
      until: now,
      handled: count_finished(since, now, "done"),
      blocked: count_finished(since, now, "blocked"),
      failed: count_finished(since, now, "failed"),
      open: count_open(),
      runs: count_runs(since, now)
    }
  end

  defp count_finished(since, until, status) do
    Repo.aggregate(
      from(i in Item,
        where: i.status == ^status and i.finished_at >= ^since and i.finished_at <= ^until
      ),
      :count
    )
  end

  defp count_open do
    Repo.aggregate(from(i in Item, where: i.status in @open_statuses), :count)
  end

  defp count_runs(since, until) do
    pattern = @run_message_prefix <> "%"

    Repo.aggregate(
      from(e in Event,
        where:
          e.category == "command_invoke" and e.inserted_at >= ^since and
            e.inserted_at <= ^until and like(e.message, ^pattern)
      ),
      :count
    )
  end
end
