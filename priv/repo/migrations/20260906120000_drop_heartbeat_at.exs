defmodule BusterClaw.Repo.Migrations.DropHeartbeatAt do
  use Ecto.Migration

  @moduledoc """
  `dispatch_items.heartbeat_at` and `shift_assignments.heartbeat_at` were added
  by `20260607195108_create_dispatch_items` and
  `20260607184830_create_shift_assignments` for a liveness signal that was never
  built.

  **The 09-05 review called this "a column nobody writes". That is not what it
  was.** Both columns *were* written — and that is the worse defect. Every write
  set them to the same instant as the row's `started_at`, in the same expression:

      # Dispatch.mark_running/2
      Map.merge(%{status: "running", started_at: now, heartbeat_at: now})

      # Orchestration.assignment_attrs/2
      started_at: now(),
      heartbeat_at: now(),

  and nothing ever refreshed them afterwards. `Dispatch.heartbeat/1` was the only
  refresher and its sole caller was a projector test using it as a convenient
  source of a bare `:dispatch_item_updated`. So on every row that has ever
  existed, `heartbeat_at == started_at` exactly, forever. A duplicate of
  `started_at` wearing a name that promises liveness is worse than a null column,
  because it reads as fresh evidence: a reader who writes
  `now - heartbeat_at > threshold` gets an answer, and the answer is the age of
  the run, not the age of its last sign of life.

  Nothing reads either column. `Dispatch.reclaim_orphans/0` — the one place that
  reasons about stranded work — decides by `status in ~w(claimed running)` alone
  and is triggered by boot and by the Dispatcher's `:DOWN` handler, not by a
  staleness timer. It also *cleared* `heartbeat_at` on reclaim, which is the only
  other write.

  Dropped rather than wired because there is no natural tick to wire it to: the
  Dispatcher's `handle_info(:tick, …)` is a no-op while a run is in flight
  (`maybe_run/1` returns immediately on `idle?/1`), and its state holds only the
  monitored pid — not the item, which for the batch path the Dispatcher never
  knows, because the spawned agent claims items through the CLI. Adding a
  heartbeat would mean inventing the state to carry it and a reader to consume
  it, which is a feature, not a cleanup. If liveness is wanted later, it should
  arrive with its reader.

  **The rollback is real.** `change/0` reverses into
  `add :heartbeat_at, :utc_datetime` — the original definition — and restores the
  full truth of the data, because the value is recoverable in full from
  `started_at`, which is the only value it ever held.
  """

  def change do
    alter table(:dispatch_items) do
      remove :heartbeat_at, :utc_datetime
    end

    alter table(:shift_assignments) do
      remove :heartbeat_at, :utc_datetime
    end
  end
end
