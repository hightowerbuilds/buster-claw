defmodule BusterClaw.EncryptedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BusterClaw.{Encrypted, Vault}

  test "loads real ciphertext back to plaintext" do
    {:ok, ciphertext} = Vault.encrypt("sk-secret")
    assert {:ok, "sk-secret"} = Encrypted.load(ciphertext)
  end

  test "passes legacy plaintext through (not framed as ciphertext)" do
    assert {:ok, "plain-legacy-key"} = Encrypted.load("plain-legacy-key")
  end

  test "loads nil as nil" do
    assert {:ok, nil} = Encrypted.load(nil)
  end

  test "fails closed on framed-but-undecryptable ciphertext (key mismatch/corruption)" do
    {:ok, <<version, rest::binary>>} = Vault.encrypt("sk-secret")
    <<last>> = :binary.part(rest, byte_size(rest) - 1, 1)

    corrupt =
      <<version>> <> :binary.part(rest, 0, byte_size(rest) - 1) <> <<Bitwise.bxor(last, 1)>>

    log =
      capture_log(fn ->
        # The raw ciphertext must NOT be handed back as if it were the plaintext
        # secret; a decrypt failure on a framed value loads as nil (absent).
        assert Encrypted.load(corrupt) == {:ok, nil}
      end)

    assert log =~ "failed to decrypt"
  end
end
