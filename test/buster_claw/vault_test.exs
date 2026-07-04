defmodule BusterClaw.VaultTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Vault

  test "round-trips a secret" do
    {:ok, ciphertext} = Vault.encrypt("sk-super-secret")
    assert ciphertext != "sk-super-secret"
    assert {:ok, "sk-super-secret"} = Vault.decrypt(ciphertext)
  end

  test "encrypts nil and empty to nil" do
    assert {:ok, nil} = Vault.encrypt(nil)
    assert {:ok, nil} = Vault.encrypt("")
  end

  test "produces a unique IV per call (ciphertexts differ)" do
    {:ok, a} = Vault.encrypt("same")
    {:ok, b} = Vault.encrypt("same")
    assert a != b
    assert {:ok, "same"} = Vault.decrypt(a)
    assert {:ok, "same"} = Vault.decrypt(b)
  end

  test "rejects tampered ciphertext (GCM tag mismatch)" do
    {:ok, <<version, rest::binary>>} = Vault.encrypt("secret")
    flipped_tail = :binary.part(rest, byte_size(rest) - 1, 1)
    <<last>> = flipped_tail

    tampered =
      <<version>> <> :binary.part(rest, 0, byte_size(rest) - 1) <> <<Bitwise.bxor(last, 1)>>

    assert {:error, :invalid_ciphertext} = Vault.decrypt(tampered)
  end

  test "encrypted?/1 recognizes our ciphertext and rejects plaintext" do
    {:ok, ciphertext} = Vault.encrypt("secret")
    assert Vault.encrypted?(ciphertext)
    refute Vault.encrypted?("plain-api-key")
    refute Vault.encrypted?(nil)
  end

  test "ciphertext?/1 recognizes the frame without decrypting" do
    {:ok, <<version, rest::binary>> = ciphertext} = Vault.encrypt("secret")
    assert Vault.ciphertext?(ciphertext)

    # A framed value whose GCM tag is corrupt is still recognized as *framed*
    # (that's the whole point — it should not be mistaken for legacy plaintext),
    # even though it no longer decrypts.
    <<last>> = :binary.part(rest, byte_size(rest) - 1, 1)

    tampered =
      <<version>> <> :binary.part(rest, 0, byte_size(rest) - 1) <> <<Bitwise.bxor(last, 1)>>

    assert Vault.ciphertext?(tampered)
    refute Vault.encrypted?(tampered)

    # Plaintext / too-short / nil are not framed.
    refute Vault.ciphertext?("plain-api-key")
    refute Vault.ciphertext?(<<1, 2, 3>>)
    refute Vault.ciphertext?(nil)
  end
end
