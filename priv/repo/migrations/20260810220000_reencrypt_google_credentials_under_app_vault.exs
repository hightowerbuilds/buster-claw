defmodule BusterClaw.Repo.Migrations.ReencryptGoogleCredentialsUnderAppVault do
  @moduledoc """
  Move the `google_accounts` `*_enc` columns from the Google vault to the app
  vault, so the app has **one vault, one AAD, one place to reason about** —
  Clinch Phase 4, finding #6.

  ## Why two vaults existed

  `BusterClaw.Google.Vault` predates `BusterClaw.Vault`. They use the same frame
  (version byte 1, 12-byte IV, 16-byte tag, AES-256-GCM) and differ only in two
  constants, which is exactly what makes them dangerous to hold in one head:

  | | key | AAD |
  |---|---|---|
  | Google | `sha256("google:v1:" <> secret_key_base)` | `buster_claw.google.vault.v1` |
  | App | `sha256("vault:v1:" <> secret_key_base)` | `buster_claw.vault.v1` |

  A value written by one cannot be read by the other, and the failure is a GCM
  authentication error at *use* time, not at write time.

  ## Why the crypto is inlined here rather than calling the vault modules

  A migration is run against whatever code exists when someone migrates — which
  includes a future tree where `BusterClaw.Google.Vault` has been deleted, which
  is the entire point of this change. A migration that calls a module scheduled
  for deletion is a migration that breaks a fresh clone later. So both key
  derivations and both AADs are literals below, taken from the modules as they
  stand today, and this file stays correct after they are gone.

  ## Failure policy: skip, never destroy

  A row whose ciphertext will not decrypt under the Google vault is **left
  exactly as it is**. That is the only safe choice — a value we cannot read is
  not a value we can re-encrypt, and overwriting it with `nil` would turn "this
  Google account needs reconnecting" into "this Google account is gone". The
  known cause is a `secret_key_base` change, which already fails closed
  everywhere else in the app (invariant 5).

  Anything skipped is counted and logged, so a partial migration is visible
  rather than silent.

  ## `down` really works

  It re-encrypts back under the Google vault using the same inlined constants.
  Reversibility here is not ceremony: this migration rewrites live credentials,
  and the cost of being wrong is every Google account needing to be reconnected
  by hand.
  """
  use Ecto.Migration

  import Ecto.Query

  require Logger

  @columns [:client_secret_enc, :refresh_token_enc, :access_token_enc]

  @version 1
  @iv_bytes 12
  @tag_bytes 16

  @google_key_prefix "google:v1:"
  @google_aad "buster_claw.google.vault.v1"

  @app_key_prefix "vault:v1:"
  @app_aad "buster_claw.vault.v1"

  def up, do: convert(from: :google, to: :app)
  def down, do: convert(from: :app, to: :google)

  defp convert(from: source, to: target) do
    rows =
      BusterClaw.Repo.all(
        from(a in "google_accounts",
          select: %{
            id: a.id,
            client_secret_enc: a.client_secret_enc,
            refresh_token_enc: a.refresh_token_enc,
            access_token_enc: a.access_token_enc
          }
        )
      )

    {converted, skipped} = Enum.reduce(rows, {0, 0}, &convert_row(&1, &2, source, target))

    Logger.info(
      "google credential re-encryption (#{source} -> #{target}): " <>
        "#{converted} value(s) converted, #{skipped} skipped"
    )

    if skipped > 0 do
      Logger.warning(
        "#{skipped} Google credential value(s) could not be decrypted under the " <>
          "#{source} vault and were LEFT UNCHANGED. The usual cause is a " <>
          "secret_key_base change; those accounts need reconnecting, but nothing " <>
          "was destroyed."
      )
    end
  end

  defp convert_row(row, {converted, skipped}, source, target) do
    Enum.reduce(@columns, {converted, skipped}, fn column, {ok, bad} ->
      case Map.fetch!(row, column) do
        nil ->
          {ok, bad}

        ciphertext ->
          case decrypt(ciphertext, source) do
            {:ok, plaintext} ->
              write_back(row.id, column, encrypt(plaintext, target))
              {ok + 1, bad}

            :error ->
              # Left exactly as found. See the failure policy above.
              {ok, bad + 1}
          end
      end
    end)
  end

  # NOT `update/3`: `import Ecto.Query` brings its own, and the collision is a
  # compile error inside a macro expansion rather than an obvious shadowing.
  defp write_back(id, column, ciphertext) do
    BusterClaw.Repo.update_all(
      from(a in "google_accounts", where: a.id == ^id),
      set: [{column, ciphertext}]
    )
  end

  defp encrypt(plaintext, vault) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(vault), iv, plaintext, aad(vault), true)

    <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>
  end

  defp decrypt(
         <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
           ciphertext::binary>>,
         vault
       ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key(vault),
           iv,
           ciphertext,
           aad(vault),
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  defp decrypt(_value, _vault), do: :error

  defp key(:google), do: :crypto.hash(:sha256, @google_key_prefix <> secret_key_base())
  defp key(:app), do: :crypto.hash(:sha256, @app_key_prefix <> secret_key_base())

  defp aad(:google), do: @google_aad
  defp aad(:app), do: @app_aad

  defp secret_key_base,
    do: BusterClaw.RuntimeConfig.secret_key_base!("Google credential re-encryption")
end
