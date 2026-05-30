defmodule BusterClaw.Encrypted do
  @moduledoc """
  Ecto type for transparently encrypted string columns.

  Values are cast and held in the struct as plaintext strings, encrypted via
  `BusterClaw.Vault` on the way to the database (`dump/1`), and decrypted on the
  way back (`load/1`). The underlying storage type is `:binary` (a SQLite BLOB).

  Legacy plaintext values written before this type was introduced are loaded
  as-is (decryption is attempted, and a non-ciphertext value passes through),
  so the column can be migrated lazily; the backfill migration re-encrypts
  existing rows so nothing remains in cleartext at rest.
  """

  use Ecto.Type

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
      {:ok, plaintext} -> {:ok, plaintext}
      # Not framed as our ciphertext — treat as a legacy plaintext value.
      {:error, _reason} -> {:ok, value}
    end
  end

  def load(_value), do: :error
end
