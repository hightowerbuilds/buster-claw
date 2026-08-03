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

  @doc ~S"""
  Indexed interactive elements: `[%{"index", "tag", "label", "selector_hint"}]`.

  `:selector` narrows the list to elements matching a CSS selector. The 07-25
  field test passed `"input,form"` and `"#variation_size_name li"` here and got
  the same nav links both times — the option was accepted and ignored, costing
  several round trips on a page with far more than 100 interactive elements.

  **Each returned element keeps its index from the full enumeration, not its
  position in the filtered list.** `click index:` resolves against the same
  unfiltered `@enumerate_js`, so renumbering a filtered result would hand back
  indices that `click` cannot honour — a quieter and worse bug than the one
  being fixed. Filtering therefore changes *which* rows come back and never what
  an index means.

  A malformed selector throws in the page and surfaces as
  `{:error, {:js_exception, _}}`, the same as `extract/3`.
  """
  def find_elements(session, opts \\ []) do
    js = """
    #{@enumerate_js}
      .map((el, index) => ({el: el, index: index}))
      #{selector_filter(Keyword.get(opts, :selector))}
      .slice(0, 100)
      .map(({el, index}) => ({
        index: index,
        tag: el.tagName.toLowerCase(),
        label: (el.innerText || el.value || el.getAttribute('aria-label') || el.placeholder || '').trim().slice(0, 120),
        selector_hint: el.id ? ('#' + el.id) : el.tagName.toLowerCase()
      }))
    """

    eval(session, js, opts)
  end

  defp selector_filter(selector) when is_binary(selector) and selector != "",
    do: ".filter(({el}) => el.matches(#{Jason.encode!(selector)}))"

  defp selector_filter(_selector), do: ""

  @doc """
  Click an element by `%{"selector" => css}`, `%{"text" => visible}`, or
  `%{"index" => n}`. Returns `{:ok, %{"clicked" => label}}`, `{:error, :no_match}`,
  or — when a `text` target matches more than one element —
  `{:error, {:ambiguous_text, count}}`. It never picks one of several.
  """
  def click(session, target, opts \\ []) do
    with {:ok, finder} <- finder_js(target) do
      js = """
      (() => {
        const found = #{finder};
        if (found.ambiguous > 1) return {matched: false, ambiguous: found.ambiguous};
        const el = found.el;
        if (!el) return {matched: false};
        const label = (el.innerText || el.value || '').trim().slice(0, 120);
        el.click();
        return {matched: true, clicked: label};
      })()
      """

      session |> eval(js, opts) |> resolve_match()
    end
  end

  @doc """
  Fill an input by the same targeting as `click/3` — including the ambiguity
  refusal — dispatching `input` and `change` so framework-bound fields notice.
  The caller resolves any secret reference before the value reaches this module
  (AgentMode's executor rule).
  """
  def fill(session, target, value, opts \\ []) when is_binary(value) do
    with {:ok, finder} <- finder_js(target) do
      js = """
      (() => {
        const found = #{finder};
        if (found.ambiguous > 1) return {matched: false, ambiguous: found.ambiguous};
        const el = found.el;
        if (!el) return {matched: false};
        el.focus();
        el.value = #{Jason.encode!(value)};
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return {matched: true, filled: el.tagName.toLowerCase()};
      })()
      """

      session |> eval(js, opts) |> resolve_match()
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

  # A finder yields `{el, ambiguous}` rather than a bare element, so the callers
  # can tell "nothing matched" (act is impossible) from "too many matched"
  # (acting would be a guess). Those are different answers and only one of them
  # is safe to paper over.
  defp finder_js(%{"selector" => selector}) when is_binary(selector) and selector != "",
    do: {:ok, "({el: document.querySelector(#{Jason.encode!(selector)}), ambiguous: 0})"}

  # Text targeting resolves in two tiers — exact match first, substring second —
  # and refuses when the winning tier has more than one member. Both halves come
  # from the 07-25 field test, where `click text: "45 inches"` matched a customer
  # *review's* variant byline ("Size: 45 inchesColor: Dark Brown") rather than the
  # size swatch, and came one unlucky DOM order away from silently carting the
  # wrong size.
  #
  # Exact-first is what keeps the ordinary case working: the real swatch reads
  # exactly "45 inches" while the review byline merely contains it. Refusing a
  # tie is what makes the ambiguous case safe — picking the first of several is
  # a guess, and a guess that reaches the cart is indistinguishable from a
  # correct answer downstream, because the cart is then cent-exact about the
  # wrong item.
  #
  # `selector` deliberately keeps `querySelector` first-match semantics: it is
  # the operator's precise instrument, `text` is the fuzzy one, so `text` is the
  # one that must not guess.
  defp finder_js(%{"text" => text}) when is_binary(text) and text != "" do
    {:ok,
     """
     (() => {
       const want = #{Jason.encode!(text)};
       const label = el => (el.innerText || el.value || '').trim();
       const all = #{@enumerate_js};
       const exact = all.filter(el => label(el) === want);
       const pool = exact.length > 0 ? exact : all.filter(el => label(el).includes(want));
       if (pool.length > 1) return {el: null, ambiguous: pool.length};
       return {el: pool[0] || null, ambiguous: 0};
     })()
     """}
  end

  defp finder_js(%{"index" => index}) when is_integer(index) and index >= 0,
    do: {:ok, "({el: #{@enumerate_js}[#{index}] || null, ambiguous: 0})"}

  defp finder_js(_target), do: {:error, :missing_target}

  # The ambiguity error carries the count and deliberately NOT the matched
  # labels. Labels are page content, and an error returned straight to the model
  # would route them around `Egress` — untracked bytes that the run summary
  # could not reconcile (acceptance criterion 12). The agent disambiguates with
  # `find_elements` or `extract`, both of which are egress-accounted.
  defp resolve_match(result) do
    case result do
      {:ok, %{"matched" => true} = value} ->
        {:ok, Map.delete(value, "matched")}

      {:ok, %{"ambiguous" => count}} when is_integer(count) and count > 1 ->
        {:error, {:ambiguous_text, count}}

      {:ok, _no_match} ->
        {:error, :no_match}

      other ->
        other
    end
  end

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
