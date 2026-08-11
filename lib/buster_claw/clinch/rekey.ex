defmodule BusterClaw.Clinch.Rekey do
  @moduledoc """
  Rotate the master key: re-encrypt every stored credential from one
  `secret_key_base` to another, in a single transaction.

  Clinch Phase 4. The gap it closes is invariant 5 — *"a rotated key never
  silently unconfigures anything"*.

  ## What went wrong without this

  Every at-rest key derives from `secret_key_base` (`BusterClaw.Vault`). Change
  it and every ciphertext in the database becomes unreadable at once. `Encrypted`
  fails closed, which is right, so nothing crashes: integrations simply load with
  `nil` tokens, Google accounts with `nil` refresh tokens, `$secret` values as
  absent. **The app looks freshly installed rather than broken**, and the data is
  still there, still encrypted, still fine — with nothing in the product able to
  say so or undo it.

  That is fail-closed with no recovery path attached. This is the recovery path.

  ## One transaction, and abort on anything unexpected

  A partial rotation is the worst outcome available: some values under the old
  key, some under the new, and no single key that reads them all. So the whole
  walk runs in one `Repo.transaction/1` and any *unexpected* failure rolls the
  lot back.

  "Unexpected" is doing real work in that sentence — see below.

  ## Two failures that are not the same

  | | meaning | response |
  |---|---|---|
  | **unreadable** | this value does not decrypt under the old key | expected; count it, leave it |
  | **error** | re-encryption itself failed | abort the whole rotation |

  A value that will not decrypt under the old key is **not** evidence the
  rotation is wrong — it is evidence that value was already unreadable *before*
  we started, which is precisely the state a previous unrecoverable key change
  leaves behind. Aborting on it would make this tool refuse to run exactly when
  it is most needed.

  So unreadable values are **left byte-for-byte as they are** and reported. They
  cannot be decrypted, so they cannot be moved, and overwriting them would
  destroy the only copy of something a restored key might still recover.

  ## What it covers

  Every `BusterClaw.Encrypted` column in the app, which after Phase 4's vault
  retirement is one vault's worth:

    * `browser_secrets.value` — `$secret` sign-ins and `:app_key` service keys
    * `integrations.token`, `integrations.webhook_secret`
    * `google_accounts.client_secret_enc` / `refresh_token_enc` / `access_token_enc`

  **This list is asserted against the schemas by `RekeyTest`**, so a new encrypted
  column that nobody adds here fails a test rather than being silently skipped by
  the next rotation — which would be a partial rotation with no error at all.

  ## What it does not do

  It does not *store* the new key. The Tauri shell owns `secret_key_base` in the
  macOS Keychain and injects it at boot (`BusterClaw.Recovery`). This module
  moves the data; making the new key the live one is the shell's job, and the
  order matters: **re-key first, adopt second.** Adopting first would leave the
  running app unable to read the values it is about to rewrite.
  """

  import Ecto.Query

  alias BusterClaw.Clinch.Vault
  alias BusterClaw.Repo

  require Logger

  # {table, [column]} — every encrypted column in the app. RekeyTest asserts this
  # against the schemas; do not add a column here without adding it there.
  @stores [
    {"browser_secrets", [:value]},
    {"integrations", [:token, :webhook_secret]},
    {"google_accounts", [:client_secret_enc, :refresh_token_enc, :access_token_enc]}
  ]

  @type report :: %{
          rekeyed: non_neg_integer(),
          unreadable: non_neg_integer(),
          skipped: [String.t()]
        }

  @doc "The tables and columns a rotation walks."
  @spec stores() :: [{String.t(), [atom()]}]
  def stores, do: @stores

  @doc """
  What a rotation could not move: stored values that are framed as our ciphertext
  but do not decrypt under the **current** key. Reads only; writes nothing.

  This is invariant 5's other half. Re-keying gives a bad key change a way *out*;
  this gives it a way to be *seen*. Without it the two states are indistinguishable
  from the UI:

    * "you have not configured anything yet" — nothing stored, and
    * "everything you configured is unreadable" — plenty stored, none of it usable

  Both render as an empty-looking app, because `Encrypted` fails closed and loads
  an unreadable value as `nil`. One of them is fine and the other is an emergency.

  Counted by *store*, not by name. A name would be more precise and is not the
  question being asked here — the operator needs to know that credentials exist
  which the current key cannot open, and roughly what they are. `Clinch.list/0`
  already names everything.

  A value that is not framed as our ciphertext at all is **not** counted: that is
  a legacy plaintext value, which `Encrypted` passes through by design, and
  reporting it as damaged would be a false alarm about something working.
  """
  @spec unreadable() :: %{count: non_neg_integer(), stores: [String.t()]}
  def unreadable do
    case current_key() do
      # No master key at all. Nothing can be read, but nothing is damaged either —
      # and telling a machine that has not been given a key yet that every
      # credential is corrupt is the false alarm this check exists to avoid.
      nil -> %{count: 0, stores: []}
      key -> scan(key)
    end
  end

  defp scan(key) do
    {count, stores} =
      Enum.reduce(@stores, {0, []}, fn {table, columns}, acc ->
        table
        |> rows(columns)
        |> Enum.reduce(acc, fn row, {n, tables} ->
          bad =
            Enum.count(columns, fn column ->
              value = Map.fetch!(row, column)

              # Framed as ours but unopenable. Anything else is either absent or
              # legacy plaintext, and neither is damage.
              Vault.ciphertext?(value) and
                match?({:error, _}, Vault.decrypt_with_current(value, key))
            end)

          if bad > 0, do: {n + bad, [table | tables]}, else: {n, tables}
        end)
      end)

    %{count: count, stores: stores |> Enum.uniq() |> Enum.sort()}
  end

  @doc """
  Re-encrypt every stored credential from `old_secret_key_base` to
  `new_secret_key_base`.

  Returns `{:ok, report}` where `report` counts what moved and what could not be
  read, or `{:error, reason}` with nothing written.

  Refuses a no-op rotation: rotating a key to itself is almost always a mistaken
  call, and doing it silently would report success for an operation that changed
  no key.
  """
  @spec run(String.t(), String.t()) :: {:ok, report()} | {:error, atom()}
  def run(old_secret_key_base, new_secret_key_base)

  def run(same, same) when is_binary(same), do: {:error, :same_key}

  def run(old_base, new_base) when is_binary(old_base) and is_binary(new_base) do
    if old_base == "" or new_base == "" do
      {:error, :blank_key}
    else
      old_key = Vault.derive_key(old_base)
      new_key = Vault.derive_key(new_base)

      case Repo.transaction(fn -> walk(old_key, new_key) end) do
        {:ok, report} -> {:ok, log(report)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def run(_old, _new), do: {:error, :invalid_key}

  defp walk(old_key, new_key) do
    Enum.reduce(@stores, %{rekeyed: 0, unreadable: 0, skipped: []}, fn {table, columns}, acc ->
      table
      |> rows(columns)
      |> Enum.reduce(acc, &rekey_row(&1, &2, table, columns, old_key, new_key))
    end)
  end

  defp rows(table, columns) do
    Repo.all(from(t in table, select: map(t, ^[:id | columns])))
  end

  defp rekey_row(row, acc, table, columns, old_key, new_key) do
    Enum.reduce(columns, acc, fn column, acc ->
      case Vault.rekey(Map.fetch!(row, column), old_key, new_key) do
        {:ok, nil} ->
          acc

        {:ok, ciphertext} ->
          write(table, row.id, column, ciphertext)
          %{acc | rekeyed: acc.rekeyed + 1}

        :unreadable ->
          # Expected, and left exactly as found. See the moduledoc: this is what a
          # previous unrecoverable key change looks like, and it is the state this
          # tool exists to be usable in.
          %{
            acc
            | unreadable: acc.unreadable + 1,
              skipped: ["#{table}.#{column}##{row.id}" | acc.skipped]
          }

        {:error, reason} ->
          # Re-encryption itself failed. A partial rotation is worse than none.
          Repo.rollback({:reencrypt_failed, table, column, reason})
      end
    end)
  end

  defp current_key do
    case BusterClaw.RuntimeConfig.secret_key_base() do
      base when is_binary(base) and base != "" -> Vault.derive_key(base)
      _ -> nil
    end
  end

  defp write(table, id, column, ciphertext) do
    Repo.update_all(from(t in table, where: t.id == ^id), set: [{column, ciphertext}])
  end

  defp log(%{rekeyed: rekeyed, unreadable: unreadable} = report) do
    Logger.info("Clinch re-key: #{rekeyed} value(s) re-encrypted, #{unreadable} unreadable")

    if unreadable > 0 do
      Logger.warning(
        "Clinch re-key: #{unreadable} value(s) could not be decrypted under the old key " <>
          "and were LEFT UNCHANGED — they were already unreadable before this rotation. " <>
          "Nothing was destroyed; those credentials need re-entering. " <>
          "Affected: #{Enum.join(Enum.reverse(report.skipped), ", ")}"
      )
    end

    %{report | skipped: Enum.reverse(report.skipped)}
  end
end
