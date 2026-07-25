defmodule BusterClaw.BrowserControl.Page do
  @moduledoc """
  Real page-interaction verbs for the CDP engine (BROWSER_ENGINE_ROADMAP
  Phase 6): read, find/click/fill, extract, wait, screenshot — the primitives a
  background flow needs, built on `Session.command` with `Runtime.evaluate`.

  Same v1 approach as the WKWebView side's Rust: interact through injected
  JavaScript in the page, not synthesized input events. Element targeting
  mirrors the tab primitives — `selector`, visible `text`, or `index` — with
  one honest difference: there is no cross-call index registry. `index` is
  positional within this module's stable enumeration of interactive elements,
  so a `find_elements` → `click index` pair is deterministic on an unchanged
  page, and any navigation renumbers.

  Every function takes the session as its first argument and accepts
  `session_mod:` (default `BusterClaw.BrowserControl.Session`) so tests run
  against a scripted CDP surface. Nothing here navigates — navigation stays
  behind `BrowserControl.navigate/3` and its scope gate.
  """

  alias BusterClaw.BrowserControl.Session

  @wait_default_ms 5_000
  @wait_cap_ms 20_000
  @wait_poll_ms 250
  @text_cap 200_000

  # Enumerate interactive elements in stable DOM order. Kept identical between
  # find_elements and index targeting so an index means the same element in both.
  @enumerate_js """
  Array.from(document.querySelectorAll('a[href], button, input, select, textarea, [role="button"], [onclick]'))
    .filter(el => el.offsetParent !== null || el.tagName === 'A')
  """

  @doc "Current URL + title."
  def current(session, opts \\ []) do
    eval(session, "({url: location.href, title: document.title})", opts)
  end

  @doc """
  Read the rendered page: url, title, visible text (capped), and links —
  the same shape `Browser`'s live render composes into markdown.
  """
  def read(session, opts \\ []) do
    js = """
    ({
      url: location.href,
      title: document.title,
      text: (document.body ? document.body.innerText : '').slice(0, #{@text_cap}),
      links: Array.from(document.querySelectorAll('a[href]')).slice(0, 200).map(a => ({
        label: (a.innerText || '').trim().slice(0, 120),
        url: a.href
      }))
    })
    """

    eval(session, js, opts)
  end

  @doc ~S|Indexed interactive elements: `[%{"index", "tag", "label", "selector_hint"}]`.|
  def find_elements(session, opts \\ []) do
    js = """
    #{@enumerate_js}
      .slice(0, 100)
      .map((el, index) => ({
        index: index,
        tag: el.tagName.toLowerCase(),
        label: (el.innerText || el.value || el.getAttribute('aria-label') || el.placeholder || '').trim().slice(0, 120),
        selector_hint: el.id ? ('#' + el.id) : el.tagName.toLowerCase()
      }))
    """

    eval(session, js, opts)
  end

  @doc """
  Click an element by `%{"selector" => css}`, `%{"text" => visible}`, or
  `%{"index" => n}`. Returns `{:ok, %{"clicked" => label}}` or
  `{:error, :no_match}`.
  """
  def click(session, target, opts \\ []) do
    with {:ok, finder} <- finder_js(target) do
      js = """
      (() => {
        const el = #{finder};
        if (!el) return {matched: false};
        const label = (el.innerText || el.value || '').trim().slice(0, 120);
        el.click();
        return {matched: true, clicked: label};
      })()
      """

      case eval(session, js, opts) do
        {:ok, %{"matched" => true} = result} -> {:ok, Map.delete(result, "matched")}
        {:ok, _no_match} -> {:error, :no_match}
        other -> other
      end
    end
  end

  @doc """
  Fill an input by the same targeting as `click/3`, dispatching `input` and
  `change` so framework-bound fields notice. The caller resolves any secret
  reference before the value reaches this module (AgentMode's executor rule).
  """
  def fill(session, target, value, opts \\ []) when is_binary(value) do
    with {:ok, finder} <- finder_js(target) do
      js = """
      (() => {
        const el = #{finder};
        if (!el) return {matched: false};
        el.focus();
        el.value = #{Jason.encode!(value)};
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return {matched: true, filled: el.tagName.toLowerCase()};
      })()
      """

      case eval(session, js, opts) do
        {:ok, %{"matched" => true} = result} -> {:ok, Map.delete(result, "matched")}
        {:ok, _no_match} -> {:error, :no_match}
        other -> other
      end
    end
  end

  @doc """
  Extract content, mirroring the tab primitive's two shapes: without `selector`
  the whole page as `%{"url", "title", "text"}`; with `selector` up to 50
  matches as `%{"count", "matches" => [%{"text", "href", "value"}]}`.
  """
  def extract(session, selector \\ nil, opts \\ [])

  def extract(session, nil, opts) do
    js = """
    ({
      url: location.href,
      title: document.title,
      text: (document.body ? document.body.innerText : '').slice(0, #{@text_cap})
    })
    """

    eval(session, js, opts)
  end

  def extract(session, selector, opts) when is_binary(selector) do
    js = """
    (() => {
      const matches = Array.from(document.querySelectorAll(#{Jason.encode!(selector)}))
        .slice(0, 50)
        .map(el => ({
          text: (el.innerText || '').trim().slice(0, 1000),
          href: el.href || null,
          value: el.value || null
        }));
      return {count: matches.length, matches: matches};
    })()
    """

    eval(session, js, opts)
  end

  @doc """
  Poll until a condition holds — the tab wait vocabulary plus a URL check:
  `%{"ready" => true}` (document fully loaded), `%{"selector" => css}` (element
  exists), `%{"visible" => css}` (element present with an on-screen box),
  `%{"text" => s}` (visible text contains), or `%{"url" => s}` (URL contains).
  Returns `{:ok, %{matched: boolean, waited_ms: n}}` — an expired budget is
  `matched: false`, not an error (the flow layer decides that's a failure).
  Options: `timeout_ms:` (default #{@wait_default_ms}, capped #{@wait_cap_ms}),
  `poll_ms:` for tests.
  """
  def wait(session, condition, opts \\ []) do
    with {:ok, js} <- condition_js(condition) do
      budget = opts |> Keyword.get(:timeout_ms, @wait_default_ms) |> min(@wait_cap_ms)
      poll = Keyword.get(opts, :poll_ms, @wait_poll_ms)
      wait_loop(session, js, budget, poll, 0, opts)
    end
  end

  @doc "PNG screenshot bytes via CDP, or a typed error."
  def screenshot(session, opts \\ []) do
    case command(session, "Page.captureScreenshot", %{}, opts) do
      {:ok, %{"data" => b64}} when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, png} -> {:ok, png}
          :error -> {:error, :bad_capture_data}
        end

      {:ok, other} ->
        {:error, {:bad_capture_result, other}}

      other ->
        other
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp wait_loop(session, js, budget, poll, waited, opts) do
    case eval(session, js, opts) do
      {:ok, true} ->
        {:ok, %{matched: true, waited_ms: waited}}

      {:ok, _falsy} when waited >= budget ->
        {:ok, %{matched: false, waited_ms: waited}}

      {:ok, _falsy} ->
        Process.sleep(poll)
        wait_loop(session, js, budget, poll, waited + poll, opts)

      other ->
        other
    end
  end

  defp condition_js(%{"ready" => true}), do: {:ok, "document.readyState === 'complete'"}

  defp condition_js(%{"selector" => selector}) when is_binary(selector) and selector != "",
    do: {:ok, "!!document.querySelector(#{Jason.encode!(selector)})"}

  defp condition_js(%{"visible" => selector}) when is_binary(selector) and selector != "" do
    {:ok,
     """
     (() => {
       const el = document.querySelector(#{Jason.encode!(selector)});
       return !!(el && el.offsetParent !== null);
     })()
     """}
  end

  defp condition_js(%{"text" => text}) when is_binary(text) and text != "" do
    {:ok, "(document.body ? document.body.innerText : '').includes(#{Jason.encode!(text)})"}
  end

  defp condition_js(%{"url" => url}) when is_binary(url) and url != "",
    do: {:ok, "location.href.includes(#{Jason.encode!(url)})"}

  defp condition_js(_condition), do: {:error, :missing_condition}

  defp finder_js(%{"selector" => selector}) when is_binary(selector) and selector != "",
    do: {:ok, "document.querySelector(#{Jason.encode!(selector)})"}

  defp finder_js(%{"text" => text}) when is_binary(text) and text != "" do
    {:ok,
     """
     #{@enumerate_js}
       .find(el => (el.innerText || el.value || '').trim().includes(#{Jason.encode!(text)}))
     """}
  end

  defp finder_js(%{"index" => index}) when is_integer(index) and index >= 0,
    do: {:ok, "#{@enumerate_js}[#{index}]"}

  defp finder_js(_target), do: {:error, :missing_target}

  # Runtime.evaluate with returnByValue; unwraps the CDP result envelope and
  # surfaces in-page exceptions as typed errors.
  defp eval(session, js, opts) do
    params = %{"expression" => js, "returnByValue" => true}

    case command(session, "Runtime.evaluate", params, opts) do
      {:ok, %{"exceptionDetails" => details}} ->
        {:error, {:js_exception, details["text"] || "evaluation failed"}}

      {:ok, %{"result" => %{"value" => value}}} ->
        {:ok, value}

      {:ok, other} ->
        {:error, {:bad_eval_result, other}}

      other ->
        other
    end
  end

  defp command(session, method, params, opts) do
    mod = Keyword.get(opts, :session_mod, Session)
    mod.command(session, method, params)
  end
end
