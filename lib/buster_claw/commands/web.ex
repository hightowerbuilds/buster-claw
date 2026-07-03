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

  def browser_fetch(%{"url" => url}), do: Browser.fetch(url, [])

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
  Click element `index` from the latest `browser_find_elements` registry,
  acting **inside the user's live, logged-in session**. Indices are per-page
  and go stale on navigation — re-find first. Every click records an explicit
  Sentinel event with its provenance (index + element label).
  """
  def browser_click(%{"index" => index}) when is_integer(index) and index >= 0 do
    with {:ok, result} <- element_action(:click, %{"index" => index}) do
      label = element_label(result)

      BusterClaw.Sentinel.observe(
        :outbound_send,
        "Clicked element ##{index} (#{label}) in the user's live tab",
        %{via: "browser_click", index: index, label: label}
      )

      {:ok, %{clicked: index, label: label}}
    end
  end

  def browser_click(_args), do: {:error, :missing_index}

  @doc """
  Fill element `index` (input/textarea/select) from the latest
  `browser_find_elements` registry with `value`, dispatching bubbling
  `input`/`change` events so framework listeners notice — acting **inside the
  user's live, logged-in session**. Indices are per-page and go stale on
  navigation — re-find first. Every fill records an explicit Sentinel event
  with its provenance (index, element label, and the value's *length* — never
  the raw value).
  """
  def browser_fill(%{"index" => index, "value" => value})
      when is_integer(index) and index >= 0 and is_binary(value) do
    with {:ok, result} <- element_action(:fill, %{"index" => index, "value" => value}) do
      label = element_label(result)

      BusterClaw.Sentinel.observe(
        :outbound_send,
        "Filled element ##{index} (#{label}) in the user's live tab",
        %{via: "browser_fill", index: index, label: label, value_length: String.length(value)}
      )

      {:ok, %{filled: index, label: label, value_length: String.length(value)}}
    end
  end

  def browser_fill(_args), do: {:error, :missing_index_or_value}

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

  def browser_open_tab(%{"url" => url}) when is_binary(url) and url != "",
    do: trigger_browser(:open_tab, url, :opened)

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
