defmodule BusterClaw.Google.BundledClient do
  @moduledoc """
  The app's own ("bundled") Google OAuth client — the credentials behind
  one-click **Connect Google** (GWS seamless-connect roadmap, Phase 0).

  `get/0` resolves, in order:

  1. **Remote config** — when `:google_bundled_client_url` is set, the JSON at
     that URL (`{"client_id": "...", "client_secret": "..."}`) is fetched
     lazily, cached in `:persistent_term`, and refreshed in the background once
     the TTL passes. `get/0` never blocks on the network: until a fetch lands
     (or whenever one fails) it falls through to the compiled config, so a dead
     buster.mom can never break connecting.
  2. **Compiled config** — the `:google_bundled_client` app env (map with
     `client_id`/`client_secret`).
  3. `nil` — bundled connect unavailable; the UI then offers only the
     Advanced (bring-your-own-client) path.

  A Desktop-app OAuth client's secret is non-confidential by Google's own
  definition of the installed-application flow — shipping it in config is the
  sanctioned pattern, and the flow itself is protected by PKCE plus the signed
  state token. Remote-over-compiled exists so the client can be rotated
  without shipping a new build.
  """

  @cache_key {__MODULE__, :remote}
  @ttl_ok :timer.hours(6)
  @ttl_error :timer.minutes(15)

  @doc """
  The bundled OAuth client as `%{client_id: id, client_secret: secret}`, or
  `nil` when none is configured (every caller must treat `nil` as "bundled
  connect unavailable").
  """
  def get, do: remote_config() || compiled_config()

  @doc "Whether one-click bundled connect is available."
  def available?, do: get() != nil

  @doc """
  Synchronously fetch + cache the remote config (test/boot helper — normal
  callers rely on `get/0`'s lazy background refresh).
  """
  def refresh do
    case config_url() do
      nil -> :ok
      url -> cache_put(fetch(url))
    end

    :ok
  end

  @doc "Drop the cached remote config (test helper)."
  def reset do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # --- internals ---------------------------------------------------------

  defp compiled_config do
    :buster_claw |> Application.get_env(:google_bundled_client) |> normalize()
  end

  defp remote_config do
    case config_url() do
      nil -> nil
      url -> cached_remote(url)
    end
  end

  defp config_url do
    case Application.get_env(:buster_claw, :google_bundled_client_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp cached_remote(url) do
    case :persistent_term.get(@cache_key, nil) do
      {value, fetched_at} ->
        ttl = if value, do: @ttl_ok, else: @ttl_error
        if now() - fetched_at > ttl, do: refresh_async(url, value)
        value

      nil ->
        refresh_async(url, nil)
        nil
    end
  end

  # Stamp the cache before spawning so concurrent get/0 calls don't all start
  # fetches; the task overwrites the stamp with the real result when it lands.
  defp refresh_async(url, stale_value) do
    cache_put(stale_value)
    run = fn -> cache_put(fetch(url)) end

    if Process.whereis(BusterClaw.SwarmTaskSupervisor) do
      Task.Supervisor.start_child(BusterClaw.SwarmTaskSupervisor, run)
    else
      spawn(run)
    end

    :ok
  end

  defp cache_put(value), do: :persistent_term.put(@cache_key, {value, now()})

  defp fetch(url) do
    request_options =
      [url: url, receive_timeout: 5_000, retry: false]
      |> Keyword.merge(Application.get_env(:buster_claw, :google_req_options, []))

    case Req.get(request_options) do
      {:ok, %{status: 200, body: body}} -> normalize(body)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp normalize(%{} = map) do
    client_id = present(pick(map, "client_id", :client_id))
    client_secret = present(pick(map, "client_secret", :client_secret))

    if client_id && client_secret do
      %{client_id: client_id, client_secret: client_secret}
    end
  end

  defp normalize(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize(decoded)
      _ -> nil
    end
  end

  defp normalize(_), do: nil

  defp pick(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
