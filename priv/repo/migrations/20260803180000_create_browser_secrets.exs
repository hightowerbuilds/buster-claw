defmodule BusterClaw.Repo.Migrations.CreateBrowserSecrets do
  use Ecto.Migration

  # The store behind `$secret.<name>` (BROWSER_CLOSEOUT Part II item 3). The
  # reference mechanism — SecretRef.resolve/mask, the executor call site, the
  # value-free trajectory — shipped long ago; what never existed was anywhere to
  # put a value, so `agent_mode.ex` defaulted its resolver to `fn _ -> :error
  # end` and every reference failed.
  #
  # `value` is `BusterClaw.Encrypted` (AES-256-GCM via `Vault`), so it is
  # ciphertext at rest and the key comes from `secret_key_base` — which the
  # Tauri shell keeps in the macOS Keychain and injects at boot. That is the
  # "Keychain-backed" requirement satisfied through the existing one-key design,
  # rather than a second Keychain integration and a new IPC surface to register.
  def change do
    create table(:browser_secrets) do
      add :name, :string, null: false
      add :value, :binary, null: false
      # What the operator called it, for the names-only listing. Never the value.
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:browser_secrets, [:name])
  end
end
