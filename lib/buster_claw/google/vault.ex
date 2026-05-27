defmodule BusterClaw.Google.Vault do
  @moduledoc "Small AES-256-GCM vault for Google OAuth credentials."

  @version 1
  @iv_bytes 12
  @tag_bytes 16
  @aad "buster_claw.google.vault.v1"

  def encrypt(nil), do: {:ok, nil}
  def encrypt(""), do: {:ok, nil}

  def encrypt(value) when is_binary(value) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    key = key()
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)

    {:ok,
     <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>}
  end

  def encrypt(_value), do: {:error, :invalid_plaintext}

  def encrypt!(value) do
    case encrypt(value) do
      {:ok, encrypted} ->
        encrypted

      {:error, reason} ->
        raise ArgumentError, "google vault encryption failed: #{inspect(reason)}"
    end
  end

  def decrypt(nil), do: {:ok, nil}

  def decrypt(
        <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :invalid_ciphertext}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_value), do: {:error, :invalid_ciphertext}

  def decrypt!(value) do
    case decrypt(value) do
      {:ok, plaintext} ->
        plaintext

      {:error, reason} ->
        raise ArgumentError, "google vault decryption failed: #{inspect(reason)}"
    end
  end

  defp key do
    :crypto.hash(:sha256, "google:v1:" <> secret_key_base())
  end

  defp secret_key_base do
    endpoint_config = Application.get_env(:buster_claw, BusterClawWeb.Endpoint, [])

    System.get_env("SECRET_KEY_BASE") ||
      Keyword.get(endpoint_config, :secret_key_base) ||
      raise "missing secret_key_base for Google credential vault"
  end
end
