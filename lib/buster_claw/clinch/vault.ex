defmodule BusterClaw.Clinch.Vault do
  @moduledoc """
  The crypto chokepoint: the **only** module that calls `BusterClaw.Vault`.
  Enforced by `Clinch.ChokepointTest`.

  ## One vault, and why this facade still earns its place

  There used to be two, with different keys and AADs, so a value written by one
  could not be read by the other. `google_accounts`' `*_enc` columns were the
  second one's. Migration `20260810220000` re-encrypted them under the app vault
  and `BusterClaw.Google.Vault` is gone — Clinch Phase 4, finding #6.

  | vault | key derivation | AAD | holds |
  |---|---|---|---|
  | `:app` | `sha256("vault:v1:" <> secret_key_base)` | `buster_claw.vault.v1` | everything encrypted at rest |

  **That collapse is the argument for the facade, made in retrospect.** Retiring a
  vault used directly by every caller would have been a change to every caller;
  routing them through here first made it this file plus a migration, exactly as
  Phase 1 predicted when it built the chokepoint.

  The `vault` argument survives at `:app` rather than being deleted. A second
  vault is a live possibility again the moment a credential needs a different key
  — a hardware-backed key, or a per-device key for Phase 6 pairing — and the
  chokepoint is worth keeping shaped for it. `Clinch.ChokepointTest` enforces that
  this stays the only caller.

  > **The two constants were documented wrong until 08-10**, with the Google AAD
  > given as `google:v1` — its key prefix. The frames were identical, so anything
  > written from the wrong constant would have failed GCM authentication at use
  > time and been unrecoverable. Recorded because the same shape recurs: when two
  > things differ only in constants, naming one of them wrongly is invisible.

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

  alias BusterClaw.Vault, as: AppVault

  @type vault :: :app

  @doc "Encrypt a value. `{:error, :invalid_plaintext}` for a non-binary."
  @spec encrypt(term(), vault()) :: {:ok, binary() | nil} | {:error, atom()}
  def encrypt(value, vault \\ :app)
  def encrypt(value, :app), do: AppVault.encrypt(value)

  @doc "Encrypt a value, raising on failure."
  @spec encrypt!(term(), vault()) :: binary() | nil
  def encrypt!(value, vault \\ :app)
  def encrypt!(value, :app), do: AppVault.encrypt!(value)

  @doc "Decrypt a value. `{:error, :invalid_ciphertext}` on a key mismatch or tampering."
  @spec decrypt(binary() | nil, vault()) :: {:ok, String.t() | nil} | {:error, atom()}
  def decrypt(value, vault \\ :app)
  def decrypt(value, :app), do: AppVault.decrypt(value)

  @doc "Decrypt a value, raising on failure."
  @spec decrypt!(binary() | nil, vault()) :: String.t() | nil
  def decrypt!(value, vault \\ :app)
  def decrypt!(value, :app), do: AppVault.decrypt!(value)

  @doc """
  True when `value` is *framed* as the app vault's ciphertext, without attempting
  decryption — the distinction `Encrypted` needs to tell a key mismatch (fail
  closed) from a legacy plaintext value (pass through).
  """
  @spec ciphertext?(term()) :: boolean()
  def ciphertext?(value), do: AppVault.ciphertext?(value)
end
