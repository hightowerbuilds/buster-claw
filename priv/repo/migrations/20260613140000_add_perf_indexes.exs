defmodule BusterClaw.Repo.Migrations.AddPerfIndexes do
  use Ecto.Migration

  def change do
    # Hot paths: Orchestration.vitals/0 filters agent_runs by started_at and
    # inserted_at (rolling-hour rate, done/failed today); list_recent_runs orders
    # by inserted_at. Only :task_id and :status were indexed before.
    create_if_not_exists index(:agent_runs, [:inserted_at])
    create_if_not_exists index(:agent_runs, [:started_at])

    # documents.date already has an index and documents.artifact_path already has
    # a UNIQUE index from the initial migration; both share the default index name
    # (documents_date_index / documents_artifact_path_index), so these
    # create_if_not_exists calls are no-ops on existing DBs and create a plain
    # (non-unique) index only where one is somehow absent. A plain index avoids
    # failing on any pre-existing duplicate artifact_path rows.
    create_if_not_exists index(:documents, [:date])
    create_if_not_exists index(:documents, [:artifact_path])

    # security_events.acknowledged_at is already indexed in create_security_events,
    # so no index is added here for Sentinel.count_unacknowledged.
  end
end
