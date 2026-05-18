defmodule BusterClaw.ApiToken do
  @moduledoc """
  Loopback API token. Loaded once at first access and cached in Application env.

  - Production: read or generate at `<user data dir>/api_token` (64 url-safe
    bytes). The same data dir holds `secret_key_base`.
  - Dev / test: pre-set in `config/dev.exs` and `config/test.exs` so the value
    is stable across restarts and reload doesn't rotate it.

  The token defends only against other local users on a shared machine — the
  Phoenix endpoint binds to `127.0.0.1`, so no remote caller can reach it.
  """

  @app :buster_claw

  @doc "Return the current token, loading it on first access."
  def value do
    case Application.get_env(@app, :api_token) do
      nil -> initialize()
      token when is_binary(token) -> token
    end
  end

  defp initialize do
    token = load_or_generate()
    Application.put_env(@app, :api_token, token)
    token
  end

  defp load_or_generate do
    path = token_path()

    case File.read(path) do
      {:ok, content} ->
        String.trim(content)

      {:error, _} ->
        token = generate()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, token)
        token
    end
  end

  defp token_path do
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
end
