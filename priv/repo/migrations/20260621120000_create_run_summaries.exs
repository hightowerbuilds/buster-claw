defmodule BusterClaw.Repo.Migrations.CreateRunSummaries do
  use Ecto.Migration

  @moduledoc """
  Cross-run memory (Phase 2, Tier 2): a structured summary of each headless agent
  run, plus an FTS5 index for `memory_search`. The index uses FTS5 external-content
  (`content='run_summaries'`) + triggers, so the index is maintained automatically
  on insert/delete and the Ecto write path stays a plain table insert.
  """

  def change do
    create table(:run_summaries) do
      add :goal, :text, null: false
      add :outcome, :string, null: false
      add :detail, :text
      add :agent, :string
      add :exit_status, :integer
      add :duration_ms, :integer
      add :provenance, :string
      add :shift_id, :integer
      add :source, :string, null: false, default: "dispatch"

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:run_summaries, [:inserted_at])

    # FTS5 index over the searchable text columns, reading from run_summaries by
    # rowid (external content). MATCH queries return rowids; the context loads the
    # structured rows back, ranked by bm25.
    execute(
      """
      CREATE VIRTUAL TABLE run_summaries_fts USING fts5(
        goal, detail, outcome,
        content='run_summaries',
        content_rowid='id'
      );
      """,
      "DROP TABLE run_summaries_fts;"
    )

    # Keep the index in sync. Rows are append-only, so insert + delete cover it.
    execute(
      """
      CREATE TRIGGER run_summaries_ai AFTER INSERT ON run_summaries BEGIN
        INSERT INTO run_summaries_fts(rowid, goal, detail, outcome)
        VALUES (new.id, new.goal, new.detail, new.outcome);
      END;
      """,
      "DROP TRIGGER run_summaries_ai;"
    )

    execute(
      """
      CREATE TRIGGER run_summaries_ad AFTER DELETE ON run_summaries BEGIN
        INSERT INTO run_summaries_fts(run_summaries_fts, rowid, goal, detail, outcome)
        VALUES ('delete', old.id, old.goal, old.detail, old.outcome);
      END;
      """,
      "DROP TRIGGER run_summaries_ad;"
    )
  end
end
