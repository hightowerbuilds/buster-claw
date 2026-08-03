defmodule BusterClaw.BrowserControl.BackgroundFlow do
  @moduledoc """
  Run a declarative browser flow on the CDP engine instead of the user's live
  tab (BROWSER_ENGINE_ROADMAP Phase 6) — same step maps, same 25-step cap, same
  report shape as `BusterClaw.Browser.FlowRunner`, which stays the single
  validator/orchestrator; this module only supplies the per-step executor.

  Where the engine is genuinely better: a saved check running unattended (the
  desktop shell may not even be open), and any flow that shouldn't hijack the
  tab the user is looking at. Co-presence stays the default engine — reading
  the live tab is a feature, not a limitation.

  Security model, inherited rather than invented: the flow's **scope is frozen
  from its own navigate steps** — the set of hosts the flow declares up front
  is the allowlist, every navigation goes through `BrowserControl.navigate/3`
  (`Scope.guard`: off-scope and payment URLs halt and land on the Sentinel
  feed), and page content can never widen it. A flow with no `navigate` step
  has nothing to act on and is refused.
  """

  alias BusterClaw.Browser.FlowRunner
  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.{Page, Pool, Scope}

  @doc """
  Validate and run `steps` on a pooled headless engine session. Returns
  `FlowRunner.run/2`'s report, `{:error, :engine_unavailable}` when no
  Chromium-family browser is installed, or a scope-derivation error.

  Options (tests): `session:` skips the pool; `session_mod:` / `navigate_mod:`
  inject the CDP/scope-gate surfaces; `wait_poll_ms:` speeds the wait loop.
  """
  def run(steps, opts \\ []) do
    with :ok <- FlowRunner.validate(steps),
         {:ok, scope} <- derive_scope(steps) do
      case Keyword.fetch(opts, :session) do
        {:ok, session} -> run_on(session, steps, scope, opts)
        :error -> run_pooled(steps, scope, opts)
      end
    end
  end

  defp run_pooled(steps, scope, opts) do
    if BrowserControl.available?() do
      Pool.with_session(fn session -> run_on(session, steps, scope, opts) end)
    else
      {:error, :engine_unavailable}
    end
  end

  defp run_on(session, steps, scope, opts) do
    FlowRunner.run(steps, exec: executor(session, scope, opts), screenshot: fn -> nil end)
  end

  @doc """
  Freeze the flow's scope from its `navigate` steps: the hosts it declares are
  the whole allowlist. Refuses a flow with no navigable host — a background
  flow that never navigates has no page to act on.
  """
  def derive_scope(steps) do
    hosts =
      for %{"action" => "navigate", "url" => url} when is_binary(url) <- steps,
          host = URI.parse(url).host,
          is_binary(host) and host != "",
          uniq: true,
          do: host

    case hosts do
      [] -> {:error, :no_navigable_host}
      hosts -> {:ok, Scope.new("background flow", hosts)}
    end
  end

  # Per-step executor over the engine: navigation through the scope gate, page
  # verbs through `Page`. Result shapes mirror the tab primitives closely
  # enough that FlowRunner's classify (wait matched / assert passed) just works.
  defp executor(session, scope, opts) do
    navigate_mod = Keyword.get(opts, :navigate_mod, BrowserControl)
    page_opts = Keyword.take(opts, [:session_mod])
    wait_opts = page_opts ++ Keyword.take(opts, [:wait_poll_ms])

    fn
      "navigate", %{"url" => url} ->
        case navigate_mod.navigate(session, scope, url, page_opts) do
          {:ok, origin} -> {:ok, %{navigated: url, origin: origin}}
          {:halt, reason, meta} -> {:error, {reason, meta[:url]}}
          other -> other
        end

      "navigate", _args ->
        {:error, :missing_url}

      "wait", args ->
        with {:ok, condition} <- wait_condition(args) do
          timeout = args |> Map.get("timeout_ms") |> wait_timeout()
          poll = Keyword.get(wait_opts, :wait_poll_ms)

          page_wait_opts =
            page_opts ++ [timeout_ms: timeout] ++ if(poll, do: [poll_ms: poll], else: [])

          with {:ok, result} <- Page.wait(session, condition, page_wait_opts) do
            {:ok, Map.put(result, :until, Map.get(args, "until", "navigation"))}
          end
        end

      "click", args ->
        Page.click(session, args, page_opts)

      "fill", args ->
        with value when is_binary(value) <- Map.get(args, "value", {:error, :missing_value}) do
          Page.fill(session, args, value, page_opts)
        end

      "extract", args ->
        Page.extract(session, Map.get(args, "selector"), page_opts)

      "find_elements", args ->
        opts = Keyword.put(page_opts, :selector, Map.get(args, "selector"))

        case Page.find_elements(session, opts) do
          {:ok, elements} -> {:ok, %{elements: elements}}
          other -> other
        end

      "assert", %{"kind" => kind, "value" => value} when is_binary(value) ->
        assert_step(session, kind, value, page_opts)

      "assert", _args ->
        {:error, :missing_kind_or_value}

      action, _args ->
        {:error, {:unsupported_action, action}}
    end
  end

  # The tab wait vocabulary (`until`/`value`) translated to Page conditions, so
  # a flow authored for the live tab runs unchanged on the engine.
  defp wait_condition(args) do
    value = Map.get(args, "value")

    case {Map.get(args, "until", "navigation"), value} do
      {"navigation", _value} -> {:ok, %{"ready" => true}}
      {"selector", v} when is_binary(v) and v != "" -> {:ok, %{"selector" => v}}
      {"visible", v} when is_binary(v) and v != "" -> {:ok, %{"visible" => v}}
      {"text", v} when is_binary(v) and v != "" -> {:ok, %{"text" => v}}
      {until, _value} when until in ~w(selector visible text) -> {:error, :missing_value}
      {_other, _value} -> {:error, :bad_wait_condition}
    end
  end

  # The tab assert kinds, read from the engine and reported in the tab's
  # `passed:` shape so FlowRunner's classify treats both engines identically.
  defp assert_step(session, kind, value, page_opts)
       when kind in ["url_contains", "title_contains"] do
    field = if kind == "url_contains", do: "url", else: "title"

    with {:ok, current} <- Page.current(session, page_opts) do
      actual = to_string(current[field] || "")
      {:ok, %{passed: String.contains?(actual, value), kind: kind, detail: actual}}
    end
  end

  defp assert_step(session, "text", value, page_opts) do
    with {:ok, %{"text" => text}} <- Page.extract(session, nil, page_opts) do
      {:ok, %{passed: String.contains?(to_string(text), value), kind: "text"}}
    end
  end

  defp assert_step(session, "selector", value, page_opts) do
    with {:ok, %{"count" => count}} <- Page.extract(session, value, page_opts) do
      {:ok, %{passed: count > 0, kind: "selector"}}
    end
  end

  defp assert_step(_session, kind, _value, _opts), do: {:error, {:unknown_assert_kind, kind}}

  defp wait_timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp wait_timeout(_ms), do: 5_000
end
