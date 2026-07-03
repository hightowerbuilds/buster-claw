defmodule BusterClaw.Browserbase do
  @moduledoc """
  Browserbase REST client — cloud browser **session lifecycle**. This is the
  control plane (create / inspect / end sessions); the sessions themselves are
  *driven* over CDP by the Node sidecar (see `BusterClaw.Browser.Sidecar`), not
  from here.

  Key-gated exactly like `BusterClaw.Finance.Finnhub`: reads
  `:buster_claw, :browserbase_api_key` (wired from `BROWSERBASE_API_KEY` in
  `config/runtime.exs`). With no key configured every call returns
  `{:error, :not_configured}` so callers degrade to the local sidecar instead of
  reaching the network tokenless. The project is inferred from the key;
  `:browserbase_project_id` is sent when present.

  Cost note: every open session bills per browser-minute, so `release/1` is the
  lever the `SessionManager` pulls on idle-timeout, shutdown, and boot-time
  reaping. Nothing here opens a session it can't close.
  """

  @base "https://api.browserbase.com/v1"
  @api_key_header "x-bb-api-key"

  @doc """
  Create a cloud browser session. Returns the id and the CDP `connect_url` the
  sidecar hands to `chromium.connectOverCDP/1`.
  """
  def create(opts \\ []) do
    body =
      case project_id() do
        {:ok, pid} -> %{projectId: pid}
        :error -> %{}
      end

    with {:ok, resp} <- request(:post, "/sessions", body, opts) do
      {:ok,
       %{
         id: resp["id"],
         connect_url: resp["connectUrl"],
         status: resp["status"],
         raw: resp
       }}
    end
  end

  @doc """
  Live-view URLs for a running session. `live_view_url` (Browserbase's
  `debuggerFullscreenUrl`) is the embeddable, interactive view we surface as a
  tab in the BusterClaw browser.
  """
  def debug(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, resp} <- request(:get, "/sessions/#{session_id}/debug", nil, opts) do
      {:ok,
       %{
         live_view_url: resp["debuggerFullscreenUrl"],
         debugger_url: resp["debuggerUrl"],
         ws_url: resp["wsUrl"],
         pages: resp["pages"] || [],
         raw: resp
       }}
    end
  end

  @doc "Retrieve a session's current state (raw body)."
  def retrieve(session_id, opts \\ []) when is_binary(session_id) do
    request(:get, "/sessions/#{session_id}", nil, opts)
  end

  @doc "List sessions for the project (raw body)."
  def list(opts \\ []) do
    request(:get, "/sessions", nil, opts)
  end

  @doc """
  End a session now (`REQUEST_RELEASE`). Idempotent from our side: an
  already-gone session is treated as released, so boot-time reaping never fails
  on a session Browserbase has already expired.
  """
  def release(session_id, opts \\ []) when is_binary(session_id) do
    body =
      case project_id() do
        {:ok, pid} -> %{projectId: pid, status: "REQUEST_RELEASE"}
        :error -> %{status: "REQUEST_RELEASE"}
      end

    case request(:post, "/sessions/#{session_id}", body, opts) do
      {:ok, _resp} -> :ok
      {:error, {:http_error, status, _body}} when status in [404, 409] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether the cloud backend is configured and enabled."
  def enabled? do
    Application.get_env(:buster_claw, :browserbase_enabled, false) and match?({:ok, _}, api_key())
  end

  # --- internals ---

  defp request(method, path, body, opts) do
    with {:ok, key} <- api_key() do
      req_options =
        opts
        |> Keyword.get(:req_options, [])
        |> Keyword.merge(
          method: method,
          url: @base <> path,
          headers: [{@api_key_header, key}, {"content-type", "application/json"}],
          receive_timeout: Keyword.get(opts, :timeout, 30_000),
          retry: false
        )
        |> maybe_put_json(body)

      case Req.request(req_options) do
        {:ok, %{status: status, body: resp}} when status in 200..299 -> {:ok, resp}
        {:ok, %{status: status, body: resp}} -> {:error, {:http_error, status, resp}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_put_json(req_options, nil), do: req_options
  defp maybe_put_json(req_options, body), do: Keyword.put(req_options, :json, body)

  defp api_key do
    case Application.get_env(:buster_claw, :browserbase_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :not_configured}
    end
  end

  defp project_id do
    case Application.get_env(:buster_claw, :browserbase_project_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end
end
