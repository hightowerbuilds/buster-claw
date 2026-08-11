defmodule BusterClaw.Vault do
  @moduledoc """
  App-wide AES-256-GCM vault for secrets stored at rest (provider API keys,
  integration tokens, webhook secrets, delivery tokens).

  The wire format is `<<version, iv::12, tag::16, ciphertext>>`. The key is
  derived from `secret_key_base`.

  **The only vault.** A second one (`BusterClaw.Google.Vault`, for the
  `google_accounts` `*_enc` columns) existed until Phase 4 re-encrypted those
  columns under this one and deleted it — migration `20260810220000`. Reach it
  through `BusterClaw.Clinch.Vault`, which is the enforced chokepoint.
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

  # ---- key-explicit variants (re-key) ----------------------------------
  #
  # A rotation has to hold TWO keys at once: read under the old one, write under
  # the new one, in a single pass. The arity-1 functions above derive the key
  # from the current `secret_key_base` at call time, so they can only ever see
  # one — which is exactly why a key change today reads as "everything is
  # suddenly nil" with no way back.
  #
  # These take the key rather than a `secret_key_base` so that the derivation
  # happens once per rotation instead of once per value, and so `derive_key/1`
  # stays the single place that knows the prefix.

  @doc """
  Derive the at-rest key from a `secret_key_base`.

  Public so a rotation can derive the OLD key after the app is already running on
  the new one. The `"vault:v1:"` prefix lives here and nowhere else.
  """
  @spec derive_key(String.t()) :: binary()
  def derive_key(secret_key_base) when is_binary(secret_key_base),
    do: :crypto.hash(:sha256, "vault:v1:" <> secret_key_base)

  @doc "Encrypt under an explicit key. See `derive_key/1`."
  @spec encrypt_with_key(term(), binary()) :: {:ok, binary() | nil} | {:error, atom()}
  def encrypt_with_key(nil, _key), do: {:ok, nil}
  def encrypt_with_key("", _key), do: {:ok, nil}

  def encrypt_with_key(value, key) when is_binary(value) and is_binary(key) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)

    {:ok,
     <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>}
  end

  def encrypt_with_key(_value, _key), do: {:error, :invalid_plaintext}

  @doc "Decrypt under an explicit key. See `derive_key/1`."
  @spec decrypt_with_key(binary() | nil, binary()) :: {:ok, String.t() | nil} | {:error, atom()}
  def decrypt_with_key(nil, _key), do: {:ok, nil}

  def decrypt_with_key(
        <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>,
        key
      )
      when is_binary(key) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :invalid_ciphertext}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt_with_key(_value, _key), do: {:error, :invalid_ciphertext}

  @doc "True when `value` is framed as this vault's ciphertext (used by the backfill migration)."
  def encrypted?(
        <<@version, _iv::binary-size(@iv_bytes), _tag::binary-size(@tag_bytes), _rest::binary>> =
          value
      ) do
    match?({:ok, _}, decrypt(value))
  end

  def encrypted?(_value), do: false

  @doc """
  True when `value` is *framed* as this vault's ciphertext (correct version byte
  and minimum length), WITHOUT attempting decryption.

  Unlike `encrypted?/1`, this does not care whether decryption succeeds — it
  distinguishes a value that is *meant* to be ciphertext (and whose decrypt
  failure therefore signals a key mismatch or corruption) from a genuinely
  unencrypted legacy plaintext value. A legacy token/API key is printable text,
  so it will not begin with the `@version` control byte and satisfy the length
  floor.
  """
  def ciphertext?(<<@version, rest::binary>>) when byte_size(rest) >= @iv_bytes + @tag_bytes,
    do: true

  def ciphertext?(_value), do: false

  # One derivation, used by both the arity-1 functions and any explicit-key
  # caller. Duplicating the prefix is how two vaults came to differ by a string.
  defp key, do: derive_key(secret_key_base())

  defp secret_key_base, do: BusterClaw.RuntimeConfig.secret_key_base!("secret vault")
end
