defmodule BusterClaw.Repo.Migrations.CreateBrowserHistoryEntries do
  use Ecto.Migration

  @moduledoc """
  Browser history moves from a flat per-workspace JSON file (capped at 50,
  deduped by URL) to a real table: one row per visit so revisit frequency is
  preserved. An FTS5 external-content index over (url, title) backs
  `BrowserHistory.search/1`; insert/delete triggers keep it in sync so the Ecto
  write path stays a plain insert.
  """

  def change do
    create table(:browser_history_entries) do
      add :url, :text, null: false
      add :title, :text, null: false
      add :visited_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:browser_history_entries, [:visited_at])
    create index(:browser_history_entries, [:url])

    # FTS5 index over the searchable columns, reading from the base table by
    # rowid (external content). MATCH queries return rowids; the context loads
    # the structured rows back, ranked by bm25.
    execute(
      """
      CREATE VIRTUAL TABLE browser_history_entries_fts USING fts5(
        url, title,
        content='browser_history_entries',
        content_rowid='id'
      );
      """,
      "DROP TABLE browser_history_entries_fts;"
    )

    execute(
      """
      CREATE TRIGGER browser_history_entries_ai AFTER INSERT ON browser_history_entries BEGIN
        INSERT INTO browser_history_entries_fts(rowid, url, title)
        VALUES (new.id, new.url, new.title);
      END;
      """,
      "DROP TRIGGER browser_history_entries_ai;"
    )

    execute(
      """
      CREATE TRIGGER browser_history_entries_ad AFTER DELETE ON browser_history_entries BEGIN
        INSERT INTO browser_history_entries_fts(browser_history_entries_fts, rowid, url, title)
        VALUES ('delete', old.id, old.url, old.title);
      END;
      """,
      "DROP TRIGGER browser_history_entries_ad;"
    )
  end
end
