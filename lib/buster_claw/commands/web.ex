defmodule BusterClaw.Commands.Web do
  @moduledoc "Web-facing commands: search, browser fetch/download/screenshot, bookmarks, and browsing history. Delegated to from `BusterClaw.Commands`."

  import BusterClaw.Commands.Helpers

  alias BusterClaw.{Browser, BrowserHistory, Search}
  alias BusterClaw.Browser.{Bridge, Capture}

  def web_search(%{"query" => query} = args) do
    limit = Map.get(args, "limit", 10)
    Search.search(query, limit: limit)
  end

  # -----------------------------------------------------------------------
  # Browser
  # -----------------------------------------------------------------------

  def browser_fetch(%{"url" => url} = args), do: Browser.fetch(url, render: render_mode(args))

  # "live" forces the desktop shell's hidden-webview render; "off" forbids it;
  # anything else lets Browser.fetch upgrade automatically when the plain
  # pipeline comes back JS-thin.
  defp render_mode(args) do
    case Map.get(args, "render") do
      "live" -> :live
      "off" -> :off
      _other -> :auto
    end
  end

  def browser_download(%{"url" => url} = args) when is_binary(url) and url != "" do
    with {:ok, dl} <- Browser.download(url) do
      filename = sanitize_download_name(Map.get(args, "filename") || dl.filename)
      rel = Path.join(["downloads", Date.to_iso8601(BusterClaw.LocalTime.today()), filename])
      abs = resolve_workspace_path(rel)

      with :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, dl.body) do
        {:ok,
         %{
           path: rel,
           absolute_path: abs,
           url: url,
           content_type: dl.content_type,
           bytes: byte_size(dl.body)
         }}
      end
    end
  end

  def browser_download(_args), do: {:error, :missing_url}

  def browser_screenshot(_args \\ %{}) do
    Capture.request()
  end

  # Agent co-presence: read and drive the live browser tab the user is viewing.

  def browser_current(_args \\ %{}) do
    Bridge.request(:current)
  end

  @doc """
  Read the active tab's **rendered DOM** — the page as the user's live session
  sees it (logged-in views included), which the server-side fetch pipeline can
  never reach. Returns `{url, title, text, links}`. Every read lands on the
  Sentinel feed: it ingests untrusted page content through the user's own
  sessions.
  """
  def browser_read(_args \\ %{}) do
    case Bridge.request(:read) do
      {:ok, %{data: raw}} when is_binary(raw) -> decode_page(raw)
      {:ok, _other} -> {:error, :bad_page_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_page(raw) do
    case Jason.decode(raw) do
      {:ok, page} when is_map(page) ->
        BusterClaw.Sentinel.observe(
          :untrusted_ingest,
          "Read live tab #{page["url"]}",
          %{url: page["url"], title: page["title"], trust: "fetched", via: "browser_read"}
        )

        {:ok,
         %{
           url: page["url"],
           title: page["title"],
           text: page["text"],
           links: page["links"] || []
         }}

      _ ->
        {:error, :bad_page_payload}
    end
  end

  @doc """
  Capture the active tab into the Library: `browser_read/1` (which records its
  own Sentinel `:untrusted_ingest` event) filed as a markdown artifact — title,
  captured-at timestamp, source URL, page text, and links — plus a best-effort
  screenshot through the same capture path `browser_screenshot/1` uses. A failed
  or timed-out screenshot never sinks the capture: the text artifact still
  lands and `screenshot` comes back `nil`.
  """
  def browser_capture_page(args \\ %{}) do
    with {:ok, page} <- browser_read(%{}) do
      title = capture_title(args, page)
      captured_at = DateTime.utc_now() |> DateTime.truncate(:second)

      with {:ok, document} <-
             BusterClaw.Library.save_raw_document(%{
               name: title,
               source_url: page.url,
               tags: ["browser-capture"],
               fetched_at: captured_at,
               content: capture_markdown(title, page, captured_at)
             }) do
        {:ok,
         %{
           document_id: document.id,
           path: document.artifact_path,
           absolute_path: BusterClaw.Library.absolute_artifact_path(document.artifact_path),
           url: page.url,
           title: title,
           screenshot: capture_screenshot()
         }}
      end
    end
  end

  defp capture_title(args, page) do
    Enum.find([Map.get(args, "title"), page.title, page.url], "Untitled page", fn value ->
      is_binary(value) and String.trim(value) != ""
    end)
  end

  defp capture_markdown(title, page, captured_at) do
    """
    # #{title}

    - Captured: #{DateTime.to_iso8601(captured_at)}
    - Source: #{page.url}

    ## Page text

    #{page.text |> to_string() |> String.trim()}
    #{links_section(page.links)}
    """
  end

  defp links_section(links) when is_list(links) and links != [] do
    "\n## Links\n\n" <> Enum.map_join(links, "\n", &link_line/1) <> "\n"
  end

  defp links_section(_links), do: ""

  defp link_line(%{"url" => url} = link) do
    case Map.get(link, "label") do
      label when is_binary(label) and label != "" -> "- [#{label}](#{url})"
      _ -> "- #{url}"
    end
  end

  defp link_line(other), do: "- #{inspect(other)}"

  # Best-effort: same machinery as `browser_screenshot/1`. Any error (no
  # desktop, timeout, desktop-reported failure) degrades to `nil`.
  defp capture_screenshot do
    case Capture.request() do
      {:ok, %{path: path}} -> path
      _other -> nil
    end
  end

  @doc """
  List the visible interactive elements (links, buttons, inputs, selects,
  textareas) of the active tab — the user's live, logged-in session. Registers
  the live element references in the page's `window.__bcEls` and returns the
  indexed descriptions `browser_click`/`browser_fill` act on. The registry is
  **per-page**: any navigation invalidates the indices, so re-find after
  navigating. Like `browser_read`, the labels are untrusted page content pulled
  into the agent's context, so every find lands on the Sentinel feed.
  """
  def browser_find_elements(args \\ %{}) do
    payload =
      case Map.get(args, "query") do
        query when is_binary(query) and query != "" -> %{"query" => query}
        _ -> %{}
      end

    case Bridge.request(:find_elements, payload) do
      {:ok, %{data: raw}} when is_binary(raw) -> decode_elements(raw, payload["query"])
      {:ok, _other} -> {:error, :bad_elements_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_elements(raw, query) do
    case Jason.decode(raw) do
      {:ok, elements} when is_list(elements) ->
        BusterClaw.Sentinel.observe(
          :untrusted_ingest,
          "Listed #{length(elements)} interactive elements in the live tab",
          %{count: length(elements), query: query, trust: "fetched", via: "browser_find_elements"}
        )

        {:ok, %{elements: elements, count: length(elements)}}

      _ ->
        {:error, :bad_elements_payload}
    end
  end

  @doc """
  Click an element in the active tab, acting **inside the user's live,
  logged-in session**. Targets, resolved desktop-side at click time in this
  order: `selector` (CSS), `text` (exact then substring match on visible
  actionable elements), or `index` from the latest `browser_find_elements`
  registry. Indices are per-page and go stale on navigation — re-find first;
  selector/text targets don't. Every click records an explicit Sentinel event
  with its provenance (target + element label + how it matched).
  """
  def browser_click(%{"selector" => selector}) when is_binary(selector) and selector != "" do
    with {:ok, result} <- element_action(:click, %{"selector" => selector}) do
      label = element_label(result)
      matched_by = matched_by(result, "selector")

      BusterClaw.Sentinel.observe(
        :outbound_send,
        ~s|Clicked element matching "#{selector}" (#{label}) in the user's live tab|,
        %{via: "browser_click", selector: selector, label: label, matched_by: matched_by}
      )

      {:ok, %{clicked: selector, label: label, matched_by: matched_by}}
    end
  end

  def browser_click(%{"text" => text}) when is_binary(text) and text != "" do
    with {:ok, result} <- element_action(:click, %{"text" => text}) do
      label = element_label(result)
      matched_by = matched_by(result, "text")

      BusterClaw.Sentinel.observe(
        :outbound_send,
        ~s|Clicked element with text "#{text}" (#{label}) in the user's live tab|,
        %{via: "browser_click", text: text, label: label, matched_by: matched_by}
      )

      {:ok, %{clicked: text, label: label, matched_by: matched_by}}
    end
  end

  def browser_click(%{"index" => index}) when is_integer(index) and index >= 0 do
    with {:ok, result} <- element_action(:click, %{"index" => index}) do
      label = element_label(result)
      matched_by = matched_by(result, "index")

      BusterClaw.Sentinel.observe(
        :outbound_send,
        "Clicked element ##{index} (#{label}) in the user's live tab",
        %{via: "browser_click", index: index, label: label, matched_by: matched_by}
      )

      {:ok, %{clicked: index, label: label, matched_by: matched_by}}
    end
  end

  def browser_click(_args), do: {:error, :missing_target}

  @doc """
  Fill a fillable element (input/textarea/select) in the active tab with
  `value`, dispatching bubbling `input`/`change` events so framework listeners
  notice — acting **inside the user's live, logged-in session**. Targets,
  resolved desktop-side at fill time in this order: `selector` (CSS), `text`
  (exact then substring match on visible actionable elements), or `index` from
  the latest `browser_find_elements` registry. Indices are per-page and go
  stale on navigation — re-find first; selector/text targets don't. Every fill
  records an explicit Sentinel event with its provenance (target, element
  label, how it matched, and the value's *length* — never the raw value).
  """
  def browser_fill(%{"selector" => selector, "value" => value})
      when is_binary(selector) and selector != "" and is_binary(value) do
    with {:ok, result} <- element_action(:fill, %{"selector" => selector, "value" => value}) do
      label = element_label(result)
      matched_by = matched_by(result, "selector")

      BusterClaw.Sentinel.observe(
        :outbound_send,
        ~s|Filled element matching "#{selector}" (#{label}) in the user's live tab|,
        %{
          via: "browser_fill",
          selector: selector,
          label: label,
          matched_by: matched_by,
          value_length: String.length(value)
        }
      )

      {:ok,
       %{
         filled: selector,
         label: label,
         matched_by: matched_by,
         value_length: String.length(value)
       }}
    end
  end

  def browser_fill(%{"text" => text, "value" => value})
      when is_binary(text) and text != "" and is_binary(value) do
    with {:ok, result} <- element_action(:fill, %{"text" => text, "value" => value}) do
      label = element_label(result)
      matched_by = matched_by(result, "text")

      BusterClaw.Sentinel.observe(
        :outbound_send,
        ~s|Filled element with text "#{text}" (#{label}) in the user's live tab|,
        %{
          via: "browser_fill",
          text: text,
          label: label,
          matched_by: matched_by,
          value_length: String.length(value)
        }
      )

      {:ok,
       %{filled: text, label: label, matched_by: matched_by, value_length: String.length(value)}}
    end
  end

  def browser_fill(%{"index" => index, "value" => value})
      when is_integer(index) and index >= 0 and is_binary(value) do
    with {:ok, result} <- element_action(:fill, %{"index" => index, "value" => value}) do
      label = element_label(result)
      matched_by = matched_by(result, "index")

      BusterClaw.Sentinel.observe(
        :outbound_send,
        "Filled element ##{index} (#{label}) in the user's live tab",
        %{
          via: "browser_fill",
          index: index,
          label: label,
          matched_by: matched_by,
          value_length: String.length(value)
        }
      )

      {:ok,
       %{filled: index, label: label, matched_by: matched_by, value_length: String.length(value)}}
    end
  end

  def browser_fill(_args), do: {:error, :missing_target_or_value}

  # Run a click/fill through the bridge and decode the page script's small JSON
  # result, so failures ("stale index — call browser_find_elements again",
  # "not fillable") surface as errors instead of silence.
  defp element_action(action, payload) do
    case Bridge.request(action, payload) do
      {:ok, %{data: raw}} when is_binary(raw) -> decode_element_result(raw)
      {:ok, _other} -> {:error, :bad_element_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_element_result(raw) do
    case Jason.decode(raw) do
      {:ok, %{"ok" => true} = result} ->
        {:ok, result}

      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) ->
        {:error, {:element_action_failed, error}}

      _ ->
        {:error, :bad_element_payload}
    end
  end

  defp element_label(result), do: result |> Map.get("label", "") |> to_string()

  # How the desktop resolved the click/fill target ("selector"|"text"|"index");
  # falls back to the target kind we sent for older desktop builds.
  defp matched_by(result, fallback), do: result |> Map.get("matched_by", fallback) |> to_string()

  @wait_conditions ~w(navigation selector visible text)
  @wait_default_ms 10_000
  @wait_cap_ms 30_000

  @doc """
  Wait for the active tab to settle or match a condition. The polling happens
  **inside the desktop shell** (every 250ms) — no page content is ingested, so
  no Sentinel event is recorded. `until`: "navigation" (default; document
  fully loaded, re-confirmed 400ms later), "selector" (CSS selector present),
  "visible" (selector present with a real on-screen box), or "text" (string
  appears in the page body). An exhausted budget is a normal
  `{:ok, %{matched: false}}` — the wait ran; the condition just never held.
  """
  def browser_wait(args \\ %{}) do
    until = Map.get(args, "until", "navigation")
    value = Map.get(args, "value")

    cond do
      until not in @wait_conditions ->
        {:error, :bad_wait_condition}

      until != "navigation" and not (is_binary(value) and value != "") ->
        {:error, :missing_value}

      true ->
        request_wait(until, value, wait_budget(Map.get(args, "timeout_ms")))
    end
  end

  defp wait_budget(ms) when is_integer(ms) and ms > 0, do: min(ms, @wait_cap_ms)
  defp wait_budget(_ms), do: @wait_default_ms

  # The desktop polls the condition for up to `budget_ms`; the bridge expiry
  # rides above it so the round-trip can't time out before the wait resolves.
  defp request_wait(condition, value, budget_ms) do
    payload = %{"condition" => condition, "value" => value, "timeout_ms" => budget_ms}

    case Bridge.request(:wait, payload, timeout_ms: budget_ms + 3_000) do
      {:ok, %{data: raw}} when is_binary(raw) -> decode_wait(raw, condition)
      {:ok, _other} -> {:error, :bad_wait_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_wait(raw, condition) do
    case Jason.decode(raw) do
      {:ok, %{"ok" => true, "matched" => matched, "waited_ms" => waited}}
      when is_boolean(matched) ->
        {:ok, %{matched: matched, waited_ms: waited, until: condition}}

      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) ->
        {:error, {:wait_failed, error}}

      _ ->
        {:error, :bad_wait_payload}
    end
  end

  @doc """
  Extract content from the active tab — the user's live, logged-in session.
  Without `selector`: the whole page as `{url, title, text}`. With `selector`:
  up to 50 matches as `{text, href/value, attr}` maps (`attr` names an
  attribute to read per match). Like `browser_read`, this pulls untrusted page
  content into the agent's context, so every extract lands on the Sentinel
  feed.
  """
  def browser_extract(args \\ %{}) do
    selector = string_or_nil(Map.get(args, "selector"))
    attr = string_or_nil(Map.get(args, "attr"))

    payload =
      %{"selector" => selector, "attr" => attr}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Bridge.request(:extract, payload) do
      {:ok, %{data: raw}} when is_binary(raw) -> decode_extract(raw, selector)
      {:ok, _other} -> {:error, :bad_extract_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp decode_extract(raw, selector) do
    case Jason.decode(raw) do
      {:ok, %{"ok" => true, "matches" => matches} = result} when is_list(matches) ->
        count = Map.get(result, "count", length(matches))

        BusterClaw.Sentinel.observe(
          :untrusted_ingest,
          ~s|Extracted #{count} matches for "#{selector}" from the live tab|,
          %{selector: selector, count: count, trust: "fetched", via: "browser_extract"}
        )

        {:ok, %{count: count, matches: matches}}

      {:ok, %{"ok" => true, "url" => url} = page} ->
        BusterClaw.Sentinel.observe(
          :untrusted_ingest,
          "Extracted live tab #{url}",
          %{url: url, title: page["title"], trust: "fetched", via: "browser_extract"}
        )

        {:ok, %{url: url, title: page["title"], text: page["text"]}}

      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) ->
        {:error, {:extract_failed, error}}

      _ ->
        {:error, :bad_extract_payload}
    end
  end

  @assert_kinds ~w(url_contains title_contains selector text)

  @doc """
  Check a condition against the active tab without acting on it. A failed
  assertion is a normal `{:ok, %{passed: false}}` — only transport/desktop
  problems are errors. `"url_contains"`/`"title_contains"` read the current
  tab; `"selector"`/`"text"` run a one-shot 250ms wait probe (present right
  now, not eventually).
  """
  def browser_assert(%{"kind" => kind, "value" => value})
      when kind in @assert_kinds and is_binary(value) and value != "" do
    case kind do
      "url_contains" -> assert_current(:url, kind, value)
      "title_contains" -> assert_current(:title, kind, value)
      "selector" -> assert_probe("selector", kind, value)
      "text" -> assert_probe("text", kind, value)
    end
  end

  def browser_assert(_args), do: {:error, :missing_kind_or_value}

  defp assert_current(field, kind, value) do
    case Bridge.request(:current) do
      {:ok, current} ->
        actual = current |> Map.get(field) |> to_string()
        {:ok, %{passed: String.contains?(actual, value), kind: kind, detail: actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assert_probe(condition, kind, value) do
    with {:ok, %{matched: matched, waited_ms: waited}} <- request_wait(condition, value, 250) do
      detail = if matched, do: "matched after #{waited}ms", else: "no match within 250ms"
      {:ok, %{passed: matched, kind: kind, detail: detail}}
    end
  end

  @doc """
  The browser's current tab strip, read from the durable per-surface tab state
  the chrome persists (`browser_tabs.<sid>` in Settings) — no desktop
  round-trip needed, and it works even while the browser is hidden.
  """
  def browser_tabs(args \\ %{}) do
    sid =
      case Map.get(args, "surface") |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "") do
        "" -> "main"
        cleaned -> cleaned
      end

    with raw when is_binary(raw) <- BusterClaw.Settings.get("browser_tabs." <> sid),
         {:ok, %{"tabs" => tabs} = state} when is_list(tabs) <- Jason.decode(raw) do
      {:ok, %{surface: sid, tabs: tabs, active: Map.get(state, "active", 0)}}
    else
      _ -> {:ok, %{surface: sid, tabs: [], active: 0}}
    end
  end

  def browser_navigate(%{"url" => url}) when is_binary(url) and url != "",
    do: trigger_browser(:navigate, url, :navigated)

  def browser_navigate(_args), do: {:error, :missing_url}

  def browser_open_tab(%{"url" => url} = args) when is_binary(url) and url != "" do
    # Agent sandbox tabs (roadmap Phase 3.4): agent-opened tabs get an
    # ephemeral, non-persistent session UNLESS session: "user" explicitly
    # grants riding the user's cookies. Anything else normalizes to ephemeral.
    session = if Map.get(args, "session") == "user", do: "user", else: "ephemeral"

    case Bridge.request(:open_tab, %{"url" => url, "session" => session}) do
      {:ok, _result} -> {:ok, %{opened: url, session: session}}
      other -> other
    end
  end

  def browser_open_tab(_args), do: {:error, :missing_url}

  # Drive the live browser via the co-presence bridge, echoing the requested URL
  # under `key` on success.
  defp trigger_browser(action, url, key) do
    case Bridge.request(action, %{"url" => url}) do
      {:ok, _result} -> {:ok, %{key => url}}
      other -> other
    end
  end

  def bookmark_add(args) do
    url = Map.get(args, "url")
    label = Map.get(args, "label")
    tags = List.wrap(Map.get(args, "tags", []))
    folder = blank_to_nil(Map.get(args, "folder"))

    if url in [nil, ""] do
      {:error, :missing_url}
    else
      BusterClaw.Bookmarks.add(url, label, tags, folder)

      {:ok,
       %{
         url: url,
         label: label || url,
         tags: BusterClaw.Bookmarks.normalize_tags(tags),
         folder: BusterClaw.Bookmarks.normalize_folder(folder)
       }}
    end
  end

  def bookmark_list(args \\ %{}) do
    tag = blank_to_nil(Map.get(args, "tag"))
    tag_opts = if tag, do: [tag: tag], else: []
    folder_opts = if Map.has_key?(args, "folder"), do: [folder: Map.get(args, "folder")], else: []

    {:ok, BusterClaw.Bookmarks.list(tag_opts ++ folder_opts)}
  end

  def bookmark_remove(%{"url" => url}) do
    BusterClaw.Bookmarks.remove(url)
    {:ok, %{removed: url}}
  end

  def bookmark_remove(_args), do: {:error, :missing_url}

  def bookmark_export(args \\ %{}) do
    case Map.get(args, "format") do
      "html" -> {:ok, %{format: "html", content: BusterClaw.Bookmarks.export_html()}}
      _ -> {:ok, %{format: "json", content: BusterClaw.Bookmarks.export()}}
    end
  end

  def bookmark_import(args) do
    incoming = Map.get(args, "bookmarks") || Map.get(args, "json")

    case BusterClaw.Bookmarks.import(incoming) do
      {:ok, count} -> {:ok, %{imported: count}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------
  # Browsing history (read-only; recording happens in the desktop shell)
  # -----------------------------------------------------------------------

  def history_search(%{"query" => query} = args) when is_binary(query) do
    case BrowserHistory.search(query, limit: normalize_limit(Map.get(args, "limit"))) do
      {:ok, entries} -> {:ok, %{entries: Enum.map(entries, &history_entry/1)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def history_search(_args), do: {:error, :missing_query}

  def history_recent(args \\ %{}) do
    entries = BrowserHistory.recent(normalize_limit(Map.get(args, "limit")))
    {:ok, %{entries: Enum.map(entries, &history_entry/1)}}
  end

  defp history_entry(entry) do
    %{url: entry.url, title: entry.title, visited_at: entry.visited_at}
  end
end
