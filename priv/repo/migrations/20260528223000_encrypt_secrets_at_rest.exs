defmodule BusterClaw.Repo.Migrations.EncryptSecretsAtRest do
  @moduledoc """
  Re-encrypts secret columns that were previously stored in cleartext.

  The columns themselves stay BLOB-compatible TEXT (SQLite stores BLOBs as-is),
  so no schema change is needed — only a data backfill. `BusterClaw.Encrypted`
  loads any value left untouched here as legacy plaintext, so the backfill is
  best-effort and idempotent: already-encrypted values are skipped.
  """

  use Ecto.Migration

  alias BusterClaw.Vault

  # {table, column} pairs that now hold encrypted secrets.
  @targets [
    {"providers", "api_key"},
    {"webhooks", "secret"},
    {"delivery_destinations", "token"},
    {"integrations", "token"},
    {"integrations", "webhook_secret"}
  ]

  def up do
    # Data migration only; runs in both directions safely (down is a no-op
    # because the type transparently reads ciphertext anyway).
    flush()
    Enum.each(@targets, &encrypt_column/1)
  end

  def down, do: :ok

  defp encrypt_column({table, column}) do
    %{rows: rows} =
      repo().query!("SELECT id, #{column} FROM #{table} WHERE #{column} IS NOT NULL", [],
        log: false
      )

    Enum.each(rows, fn [id, value] ->
      unless Vault.encrypted?(value) do
        repo().query!(
          "UPDATE #{table} SET #{column} = ? WHERE id = ?",
          [Vault.encrypt!(value), id],
          log: false
        )
      end
    end)
  end
end
