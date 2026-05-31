defmodule BusterClaw.ApiToken do
  @moduledoc """
  Loopback API token. Loaded once at first access and cached in Application env.

  - Production: read or generate at `<user data dir>/api_token` (32 random
    bytes, url-safe base64-encoded). The same data dir holds `secret_key_base`.
  - Dev / test: pre-set in `config/dev.exs` and `config/test.exs` via
    `config :buster_claw, :api_token, "..."`. Reload doesn't rotate.

  ## Filesystem hygiene

  When the token file is created (or read), the file is chmod-ed to `0o600`
  and the parent directory to `0o700` on POSIX systems. Windows is a no-op
  since it has no equivalent POSIX modes.

  ## Test override

  Tests can override the on-disk path via `config :buster_claw,
  :api_token_path, "/tmp/..."` so they never touch the real `~/Library` path.

  The token defends only against other local users on a shared machine — the
  Phoenix endpoint binds to `127.0.0.1`, so no remote caller can reach it.
  """

  @app :buster_claw

  @doc "Return the full-access API token, loading it on first access."
  def value do
    case Application.get_env(@app, :api_token) do
      nil -> initialize()
      token when is_binary(token) -> token
    end
  end

  @doc """
  Return the scoped MCP token, loading it on first access.

  This is a *distinct* token handed to external MCP agents. It authenticates as
  the `:mcp` caller, which `BusterClaw.Commands.call/3` restricts to safe-tier
  commands. Generated and stored next to the full token (`mcp_token`) in
  production; preset via `config :buster_claw, :mcp_api_token` in dev/test.
  """
  def mcp_value do
    case Application.get_env(@app, :mcp_api_token) do
      nil -> initialize_mcp()
      token when is_binary(token) -> token
    end
  end

  defp initialize do
    token = load_or_generate(token_path())
    Application.put_env(@app, :api_token, token)
    token
  end

  defp initialize_mcp do
    token = load_or_generate(mcp_token_path())
    Application.put_env(@app, :mcp_api_token, token)
    token
  end

  defp load_or_generate(path) do
    case File.read(path) do
      {:ok, content} ->
        # Re-tighten mode on every read so upgrades from older code that
        # wrote with the default umask get fixed up.
        maybe_chmod(path, 0o600)
        String.trim(content)

      {:error, _} ->
        token = generate()
        dir = Path.dirname(path)
        File.mkdir_p!(dir)
        maybe_chmod(dir, 0o700)
        File.write!(path, token)
        maybe_chmod(path, 0o600)
        token
    end
  end

  defp token_path do
    case Application.get_env(@app, :api_token_path) do
      nil -> default_token_path()
      path when is_binary(path) -> path
    end
  end

  defp mcp_token_path do
    case Application.get_env(@app, :mcp_api_token_path) do
      nil -> Path.join(Path.dirname(token_path()), "mcp_token")
      path when is_binary(path) -> path
    end
  end

  defp default_token_path do
    base =
      case :os.type() do
        {:unix, :darwin} -> Path.expand("~/Library/Application Support/BusterClaw")
        _ -> Path.expand("~/.buster_claw")
      end

    Path.join(base, "api_token")
  end

  defp generate do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp maybe_chmod(path, mode) do
    case :os.type() do
      {:unix, _} -> File.chmod!(path, mode)
      _ -> :ok
    end
  end
end
