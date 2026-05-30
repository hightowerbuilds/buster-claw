defmodule BusterClaw.Vault do
  @moduledoc """
  App-wide AES-256-GCM vault for secrets stored at rest (provider API keys,
  integration tokens, webhook secrets, delivery tokens).

  The wire format is `<<version, iv::12, tag::16, ciphertext>>`. The key is
  derived from `secret_key_base`; see `BusterClaw.Google.Vault` for the
  equivalent Google-credential vault that predates this module.
  """

  @version 1
  @iv_bytes 12
  @tag_bytes 16
  @aad "buster_claw.vault.v1"

  def encrypt(nil), do: {:ok, nil}
  def encrypt(""), do: {:ok, nil}

  def encrypt(value) when is_binary(value) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, value, @aad, true)

    {:ok,
     <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>}
  end

  def encrypt(_value), do: {:error, :invalid_plaintext}

  def encrypt!(value) do
    case encrypt(value) do
      {:ok, encrypted} -> encrypted
      {:error, reason} -> raise ArgumentError, "vault encryption failed: #{inspect(reason)}"
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
      {:ok, plaintext} -> plaintext
      {:error, reason} -> raise ArgumentError, "vault decryption failed: #{inspect(reason)}"
    end
  end

  @doc "True when `value` is framed as this vault's ciphertext (used by the backfill migration)."
  def encrypted?(
        <<@version, _iv::binary-size(@iv_bytes), _tag::binary-size(@tag_bytes), _rest::binary>> =
          value
      ) do
    match?({:ok, _}, decrypt(value))
  end

  def encrypted?(_value), do: false

  defp key do
    :crypto.hash(:sha256, "vault:v1:" <> secret_key_base())
  end

  defp secret_key_base do
    endpoint_config = Application.get_env(:buster_claw, BusterClawWeb.Endpoint, [])

    System.get_env("SECRET_KEY_BASE") ||
      Keyword.get(endpoint_config, :secret_key_base) ||
      raise "missing secret_key_base for secret vault"
  end
end
