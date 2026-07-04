defmodule BusterClaw.Encrypted do
  @moduledoc """
  Ecto type for transparently encrypted string columns.

  Values are cast and held in the struct as plaintext strings, encrypted via
  `BusterClaw.Vault` on the way to the database (`dump/1`), and decrypted on the
  way back (`load/1`). The underlying storage type is `:binary` (a SQLite BLOB).

  Legacy plaintext values written before this type was introduced are loaded
  as-is (a value that is not framed as our ciphertext passes through), so the
  column can be migrated lazily; the backfill migration re-encrypts existing
  rows so nothing remains in cleartext at rest.

  A value that *is* framed as ciphertext but fails to decrypt (a key rotation /
  mismatch, or a tampered/corrupt blob) is NOT treated as plaintext — that would
  hand the raw ciphertext bytes back as if they were the secret. Instead it fails
  closed: the failure is logged loudly and the field loads as `nil` (absent), so
  the affected integration reads as unconfigured rather than acting on garbage.
  """

  use Ecto.Type

  require Logger

  alias BusterClaw.Vault

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(""), do: {:ok, nil}

  def dump(value) when is_binary(value) do
    case Vault.encrypt(value) do
      {:ok, encrypted} -> {:ok, encrypted}
      {:error, _reason} -> :error
    end
  end

  def dump(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case Vault.decrypt(value) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, _reason} ->
        if Vault.ciphertext?(value) do
          # Framed as our ciphertext but decryption failed — a key mismatch or a
          # corrupt/tampered blob, not legacy plaintext. Fail closed: surface it
          # and load as nil rather than returning ciphertext bytes as the secret.
          Logger.error(
            "Encrypted: stored ciphertext failed to decrypt (key rotation/mismatch or " <>
              "corruption); loading the field as nil"
          )

          {:ok, nil}
        else
          # Not framed as our ciphertext — a legacy plaintext value; pass through
          # for lazy migration.
          {:ok, value}
        end
    end
  end

  def load(_value), do: :error
end
