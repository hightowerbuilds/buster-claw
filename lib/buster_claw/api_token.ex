defmodule BusterClaw.ApiToken do
  @moduledoc """
  Loopback API token. Loaded once at first access and cached in Application env.

  - Packaged app: the Tauri shell holds all three tokens in the **macOS
    Keychain** and injects them as `BUSTER_CLAW_*_API_TOKEN`, which
    `config/runtime.exs` reads into app env. Nothing here touches the disk.
  - Manual release run outside the shell: read or generate at
    `<user data dir>/<name>` (32 random bytes, url-safe base64-encoded).
  - Dev / test: pre-set in `config/dev.exs` and `config/test.exs` via
    `config :buster_claw, :api_token, "..."`. Reload doesn't rotate.

  ## Filesystem hygiene

  The file path is a fallback, not the normal path — a packaged install should
  never create one. When it is used, the file is chmod-ed to `0o600` and the
  parent directory to `0o700` on POSIX systems (Windows is a no-op, having no
  equivalent modes), and the shell adopts any such file into the Keychain and
  deletes it on next launch.

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

  @doc """
  Return the agent-untrusted provenance token, loading it on first access.

  A *distinct* token the Dispatcher hands a headless run whose work originates
  from untrusted content. It authenticates as the `:agent_untrusted` caller,
  which `BusterClaw.Commands.call/3` allows to do a lot but refuses the `gated`
  (outbound/irreversible) commands. Keychain-backed and injected as
  `BUSTER_CLAW_AGENT_API_TOKEN` by the shell, exactly like its two siblings;
  preset via `config :buster_claw, :agent_api_token` in dev/test.
  """
  def agent_value do
    case Application.get_env(@app, :agent_api_token) do
      nil -> initialize_agent()
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

  @doc """
  Return the terminal token, loading it on first access.

  A *distinct* token the desktop shell injects into the in-app PTY. It
  authenticates as the `:terminal` caller, which runs **every command the full
  token runs** — dispatch work, sends, deletes — and is refused by
  `BusterClawWeb.RequireTrusted`, so credential *management* is unreachable from
  a shell.

  ## Why the terminal needed its own token at all

  `RequireTrusted`'s own reasoning was that the full token is safe because it
  lives in the Keychain and the shell's process environment, and an attacker
  "gets no shell and therefore no Keychain". **The in-app terminal is a shell,
  and it had the full token in its environment** — so an agent running there had
  exactly the capability that argument says is out of reach, and could store,
  delete, or rotate credentials. Clinch finding #7.

  The Clinch's founding rule is that a caller may *use* a credential and never
  *manage* one. This is what makes that true where an agent has a prompt.

  Keychain-backed and injected as `BUSTER_CLAW_API_TOKEN` **into the PTY only**;
  the shell keeps the full token for its own management calls. Preset via
  `config :buster_claw, :terminal_api_token` in dev/test.
  """
  def terminal_value do
    case Application.get_env(@app, :terminal_api_token) do
      nil -> initialize_terminal()
      token when is_binary(token) -> token
    end
  end

  defp initialize_terminal do
    token = load_or_generate(terminal_token_path())
    Application.put_env(@app, :terminal_api_token, token)
    token
  end

  defp initialize_agent do
    token = load_or_generate(agent_token_path())
    Application.put_env(@app, :agent_api_token, token)
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

  defp terminal_token_path do
    case Application.get_env(@app, :terminal_api_token_path) do
      nil -> Path.join(Path.dirname(token_path()), "terminal_token")
      path when is_binary(path) -> path
    end
  end

  defp agent_token_path do
    case Application.get_env(@app, :agent_api_token_path) do
      nil -> Path.join(Path.dirname(token_path()), "agent_token")
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
