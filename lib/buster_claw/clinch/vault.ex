defmodule BusterClaw.Clinch.Vault do
  @moduledoc """
  The crypto chokepoint: the **only** module that calls `BusterClaw.Vault` or
  `BusterClaw.Google.Vault`. Enforced by `Clinch.ChokepointTest`.

  ## Why a facade over two vaults

  There are two, and they are not interchangeable — different AAD, different key
  derivation, so a value written by one cannot be read by the other:

  | vault | module, key derivation, AAD | holds |
  |---|---|---|
  | `:app` | `BusterClaw.Vault` · key `sha256("vault:v1:" <> secret_key_base)` · AAD `buster_claw.vault.v1` | integration tokens, webhook secrets, `$secret` and `:app_key` values |
  | `:google` | `BusterClaw.Google.Vault` · key `sha256("google:v1:" <> secret_key_base)` · AAD `buster_claw.google.vault.v1` | the `google_accounts` `*_enc` columns |

  > **Both are listed with key AND AAD because this table used to conflate them.**
  > It gave the `:google` AAD as `google:v1`, which is the KEY DERIVATION prefix —
  > the AAD is `buster_claw.google.vault.v1`. The frames are otherwise identical
  > (version byte 1, 12-byte IV, 16-byte tag), so anything written from the wrong
  > constant looks correct and fails GCM authentication forever. Found 08-10 while
  > scoping the Phase 4 migration that would have been written from this table.

  Clinch Phase 4 retires `:google` by re-encrypting those columns under `:app`
  and deleting the second vault. Routing both through one facade first is what
  makes that a change to *this file plus a migration*, rather than a change to
  every caller — which is the whole argument for a chokepoint.

  ## Deliberately dependency-free

  This module knows nothing about `Repo`, `Sentinel`, or `Clinch` itself. That is
  load-bearing, not incidental: `BusterClaw.Encrypted` is an Ecto type that runs
  on every row load, and pulling the audit spine or the repo into its compile
  path would drag them into every schema in the app. The audited, semantic verb
  lives in `Clinch.resolve/2`; this is bytes in, bytes out.

  It is also why there is **no audit event here**. `Encrypted.load/1` fires once
  per row per query — a `credential_use` row for each would turn one listing of
  fifty integrations into fifty writes, and an audit feed nobody can read is the
  same as no audit feed. Auditing belongs at the point a credential is used to
  *act*, which is a decision only the caller can make.
  """

  alias BusterClaw.Google.Vault, as: GoogleVault
  alias BusterClaw.Vault, as: AppVault

  @type vault :: :app | :google

  @doc "Encrypt a value. `{:error, :invalid_plaintext}` for a non-binary."
  @spec encrypt(term(), vault()) :: {:ok, binary() | nil} | {:error, atom()}
  def encrypt(value, vault \\ :app)
  def encrypt(value, :app), do: AppVault.encrypt(value)
  def encrypt(value, :google), do: GoogleVault.encrypt(value)

  @doc "Encrypt a value, raising on failure."
  @spec encrypt!(term(), vault()) :: binary() | nil
  def encrypt!(value, vault \\ :app)
  def encrypt!(value, :app), do: AppVault.encrypt!(value)
  def encrypt!(value, :google), do: GoogleVault.encrypt!(value)

  @doc "Decrypt a value. `{:error, :invalid_ciphertext}` on a key mismatch or tampering."
  @spec decrypt(binary() | nil, vault()) :: {:ok, String.t() | nil} | {:error, atom()}
  def decrypt(value, vault \\ :app)
  def decrypt(value, :app), do: AppVault.decrypt(value)
  def decrypt(value, :google), do: GoogleVault.decrypt(value)

  @doc "Decrypt a value, raising on failure."
  @spec decrypt!(binary() | nil, vault()) :: String.t() | nil
  def decrypt!(value, vault \\ :app)
  def decrypt!(value, :app), do: AppVault.decrypt!(value)
  def decrypt!(value, :google), do: GoogleVault.decrypt!(value)

  @doc """
  True when `value` is *framed* as the app vault's ciphertext, without attempting
  decryption — the distinction `Encrypted` needs to tell a key mismatch (fail
  closed) from a legacy plaintext value (pass through).
  """
  @spec ciphertext?(term()) :: boolean()
  def ciphertext?(value), do: AppVault.ciphertext?(value)
end
