defmodule BusterClaw.Repo.Migrations.AddKindToBrowserSecrets do
  @moduledoc """
  Give `browser_secrets` a `kind`, so the Clinch's one encrypted store can hold
  more than `$secret.<name>` sign-in values.

  Phase 3 moves the Twilio, Supabase service-role and Finnhub credentials out of
  `runtime.exs` and into the Clinch, which makes them rotatable and revocable —
  something an environment variable has never been. They are `service_key`s, and
  they need somewhere encrypted to live.

  **One table rather than a second one**, because Phase 4's stated goal is "one
  vault, one AAD, one place to reason about" — adding a table now would be work
  to undo then. The table keeps its `browser_secrets` name for the reason it
  already carried: it was created when the store belonged to `BrowserControl`,
  and renaming buys nothing.

  Existing rows are all `sign_in` by definition — that was the only writable kind
  before today — so the backfill is a default, not a guess.

  The unique index moves from `name` to `(kind, name)`. A service key called
  `twilio` and a sign-in value called `twilio` are different credentials, and
  making them collide would be an accident waiting rather than a safeguard.
  """
  use Ecto.Migration

  def up do
    alter table(:browser_secrets) do
      add :kind, :string, null: false, default: "sign_in"
    end

    # Was unique on name alone (20260803180000); a name is only unique within
    # its kind now.
    drop unique_index(:browser_secrets, [:name])

    create unique_index(:browser_secrets, [:kind, :name])
  end

  def down do
    drop_if_exists unique_index(:browser_secrets, [:kind, :name])

    # Only `sign_in` rows can survive the rollback: with the column gone their
    # names would collide, and silently dropping the collision is worse than
    # dropping the rows that could not have existed before this migration.
    execute "DELETE FROM browser_secrets WHERE kind != 'sign_in'"

    alter table(:browser_secrets) do
      remove :kind
    end

    create unique_index(:browser_secrets, [:name])
  end
end
