defmodule BusterClaw.Browser.SessionClient do
  @moduledoc """
  Thin HTTP client for the sidecar's stateful `/session/*` endpoints — the seam
  between the BEAM and a live Playwright session driving a Browserbase cloud
  browser over CDP.

  The `BusterClaw.Browserbase.SessionManager` creates/releases the Browserbase
  session (it holds the API key and the billing lever) and hands this client the
  session's `connect_url`; the sidecar only drives it. Every call maps the
  sidecar's wire contract to tagged errors so the manager can reconcile:

    * `404 unknown_session` → `{:error, {:unknown_session, id}}` — the handle is
      gone (sidecar restarted, or the session was dropped). Reconnect or reap.
    * `409 session_closed`  → `{:error, {:session_closed, id}}` — the cloud
      session died underneath us mid-call.
  """

  alias BusterClaw.Browser.Sidecar

  @doc "Open a driven session against a Browserbase `connect_url`. Returns the sidecar id."
  def open(connect_url, opts \\ []) do
    post(
      "/session/open",
      %{
        connectUrl: connect_url,
        bbSessionId: Keyword.get(opts, :bb_session_id),
        timeout_ms: Keyword.get(opts, :timeout, 15_000)
      },
      opts
    )
  end

  def navigate(id, url, opts \\ []) do
    post(
      "/session/navigate",
      %{id: id, url: url, wait_until: Keyword.get(opts, :wait_until, "domcontentloaded")},
      opts
    )
  end

  def read(id, opts \\ []), do: post("/session/read", %{id: id}, opts)

  def fill(id, selector, value, opts \\ []) do
    post("/session/fill", %{id: id, selector: selector, value: value}, opts)
  end

  def select(id, selector, value, opts \\ []) do
    post("/session/select", %{id: id, selector: selector, value: value}, opts)
  end

  def click(id, selector, opts \\ []) do
    post("/session/click", %{id: id, selector: selector}, opts)
  end

  def find_elements(id, query, opts \\ []) do
    post(
      "/session/find_elements",
      %{id: id, query: query, limit: Keyword.get(opts, :limit, 20)},
      opts
    )
  end

  def screenshot(id, opts \\ []) do
    post("/session/screenshot", %{id: id, full_page: Keyword.get(opts, :full_page, false)}, opts)
  end

  def extract(id, spec, opts \\ []) do
    post("/session/extract", %{id: id, spec: spec}, opts)
  end

  @doc "Close a driven session. Idempotent — an unknown id is treated as already closed."
  def close(id, opts \\ []) do
    case post("/session/close", %{id: id}, opts) do
      {:ok, _body} -> :ok
      {:error, {:unknown_session, _}} -> :ok
      other -> other
    end
  end

  # --- internals ---

  defp post(path, body, opts) do
    with {:ok, base} <- base_url(opts) do
      timeout = Keyword.get(opts, :timeout, 15_000)

      request_options =
        [json: body, receive_timeout: timeout + 5_000, retry: false]
        |> Keyword.merge(Application.get_env(:buster_claw, :browser_sidecar_req_options, []))
        |> Keyword.merge(Keyword.get(opts, :sidecar_req_options, []))

      case Req.post(base <> path, request_options) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          {:ok, resp}

        {:ok, %{status: 404, body: resp}} ->
          {:error, {:unknown_session, value(resp, "id")}}

        {:ok, %{status: 409, body: resp}} ->
          {:error, {:session_closed, value(resp, "id")}}

        {:ok, %{status: status, body: resp}} ->
          {:error, {:sidecar_bad_status, status, resp}}

        {:error, reason} ->
          {:error, {:sidecar_request_failed, reason}}
      end
    end
  end

  defp base_url(opts) do
    cond do
      url = Keyword.get(opts, :sidecar_url) -> {:ok, url}
      url = Application.get_env(:buster_claw, :browser_sidecar_url) -> {:ok, url}
      match?({:ok, _}, Sidecar.url()) -> Sidecar.url()
      true -> {:error, :sidecar_unavailable}
    end
  end

  # Sidecar responses are JSON (string keys); no atom fallback needed.
  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil
end
