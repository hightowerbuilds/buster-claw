defmodule BusterClawWeb.Browser.HomePage do
  @moduledoc """
  The in-app browser's homepage: saved bookmarks as cards, grouped by folder,
  above the recent-history list.

  Markup only; `BusterClawWeb.BrowserHomeController` does the reading. The
  search box and tag chips are inert here — the filtering is client-side, in
  `assets/js/browser_pages.js`, over the `data-search` / `data-tags` attributes
  these cards carry.

  ## `safe_href/1` still exists on purpose

  HEEx escapes every interpolation, so the old private `escape/1` is gone. It
  does **not** neutralise a `javascript:` URL in an `href`, though: escaping
  makes the attribute safe to *parse*, not safe to *click*. So the allowlist
  survives the move, and is the one piece of the old string-building that was
  never really about escaping.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Browser.Layout

  alias BusterClaw.Bookmarks
  alias BusterClawWeb.Browser.Layout

  @css """
  h2 .more { margin-left: 10px; font: 600 11px/1 var(--mono);
             letter-spacing: 0; text-transform: none; color: var(--accent);
             text-decoration: none; display: inline; padding: 0; }
  h2 .more:hover { text-decoration: underline; }
  li { display: flex; align-items: center; }
  li a { flex: 1 1 auto; }
  .label { font-weight: 600; flex: 0 0 auto; max-width: 22rem; overflow: hidden;
           text-overflow: ellipsis; white-space: nowrap; }
  .url { flex: 1 1 auto; min-width: 0; }
  form.rm { margin: 0; flex: 0 0 auto; }
  button.rm { background: transparent; border: 0; cursor: pointer; padding: 4px 8px;
              color: rgba(244,241,234,.4); font-size: 16px; line-height: 1; }
  button.rm:hover { color: var(--accent); }

  /* Bookmark cards */
  .grid { display: grid; gap: 12px; margin: 12px 0 0; max-width: 60rem;
          grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
  .card { position: relative; border: 1px solid var(--dimmer);
          border-radius: 8px; background: rgba(244,241,234,.02);
          transition: border-color .15s ease, background .15s ease, transform .15s ease; }
  .card:hover { border-color: rgba(255,77,28,.55); background: rgba(255,77,28,.05);
                transform: translateY(-1px); }
  .card > a { display: block; padding: 14px; text-decoration: none; color: var(--fg); }
  .card .head { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .card .fav { width: 20px; height: 20px; flex: 0 0 auto; border-radius: 4px;
               background: rgba(244,241,234,.08); }
  .card .label { font-weight: 700; font-size: 14px; overflow: hidden;
                 text-overflow: ellipsis; white-space: nowrap; max-width: none; }
  .card .host { margin-top: 8px; color: var(--dim);
                font: 12px/1.3 var(--mono); overflow: hidden;
                text-overflow: ellipsis; white-space: nowrap; }
  .card .tags { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
  .card .rm { position: absolute; top: 6px; right: 6px; opacity: 0; transition: opacity .15s ease; }
  .card:hover .rm { opacity: 1; }
  .tag { font: 600 10px/1 var(--mono); padding: 3px 7px;
         background: rgba(255,77,28,.18); color: var(--accent); border-radius: 3px;
         text-transform: uppercase; letter-spacing: .04em; }
  h3.folder { margin: 22px 0 0; font: 700 12px/1 var(--mono);
              letter-spacing: .08em; text-transform: uppercase;
              color: rgba(244,241,234,.7); }
  h3.folder::before { content: "▸ "; color: var(--accent); }

  /* Search + tag filters */
  .controls { display: flex; flex-wrap: wrap; align-items: center; gap: 10px;
              margin: 14px 0 0; max-width: 60rem; }
  #search { flex: 1 1 220px; min-width: 180px; padding: 9px 12px;
            background: rgba(244,241,234,.04); border: 1px solid rgba(244,241,234,.16);
            border-radius: 6px; color: var(--fg); font: 14px/1 -apple-system, system-ui, sans-serif; }
  #search:focus { outline: none; border-color: rgba(255,77,28,.6); }
  #search::placeholder { color: rgba(244,241,234,.4); }
  .filters { display: flex; flex-wrap: wrap; gap: 6px; }
  .filter { cursor: pointer; border: 1px solid rgba(255,77,28,.35); background: transparent;
            color: var(--accent); font: 600 10px/1 var(--mono); padding: 4px 8px;
            border-radius: 3px; text-transform: uppercase; letter-spacing: .04em;
            transition: background .12s ease; }
  .filter:hover { background: rgba(255,77,28,.12); }
  .filter[aria-pressed="true"] { background: var(--accent); color: var(--bg);
                                 border-color: var(--accent); }
  #clear { background: transparent; border: 0; cursor: pointer; padding: 4px 6px;
           color: rgba(244,241,234,.5); font: 12px/1 -apple-system, system-ui, sans-serif;
           text-decoration: underline; }
  #clear:hover { color: var(--accent); }
  #clear[hidden] { display: none; }
  .nomatch { color: var(--label); margin: 14px 0 0; }
  .nomatch[hidden] { display: none; }
  """

  defp css, do: @css

  @doc """
  Render the browser homepage to a binary.

  Takes `%{bookmarks: [map], history: [entry]}`. Not declared with `attr`: this
  is called by hand from a controller, where `attr` never validates anything.
  """
  def html(assigns) do
    ~H"""
    <.browser_page title="Browser" eyebrow="Browser" heading="Home" css={css()}>
      <h2>Bookmarks</h2>

      <div :if={@bookmarks != []} class="controls">
        <input type="search" id="search" placeholder="Search bookmarks…" autocomplete="off" />
        <div :if={tags_of(@bookmarks) != []} class="filters">
          <button
            :for={tag <- tags_of(@bookmarks)}
            type="button"
            class="filter"
            data-tag={tag}
            aria-pressed="false"
          >
            {tag}
          </button>
        </div>
        <button type="button" id="clear" hidden>Clear</button>
      </div>

      <p :if={@bookmarks == []} class="empty">
        No bookmarks yet. Open a page and press <code>+ Bookmark</code> in the
        toolbar above to save it here — it'll show up as a card with its favicon and any tags.
      </p>

      <.folder :for={group <- Bookmarks.group(@bookmarks)} group={group} />

      <p class="nomatch" id="nomatch" hidden>No bookmarks match.</p>

      <h2>Recent <a class="more" href="/browser/history">Full history →</a></h2>

      <p :if={@history == []} class="empty">
        No recent pages yet. Type a URL (e.g. <code>apnews.com</code>) or an
        absolute workspace path (e.g. <code>/library/notes.md</code>) in the address bar above.
      </p>

      <ul :if={@history != []}>
        <li :for={entry <- @history}>
          <a href={safe_href(entry.url)}>
            <span class="label">{entry.title || entry.url}</span>
            <span class="url">{entry.url}</span>
          </a>
        </li>
      </ul>
    </.browser_page>
    """
    |> Layout.to_html()
  end

  # Bookmarks render grouped by folder: the root (folderless) grid first, then a
  # labelled grid per folder (A→Z). Older flat files with no folder land at root.
  attr :group, :any, required: true

  defp folder(%{group: {name, items}} = assigns) do
    assigns = Map.merge(assigns, %{name: name, items: items})

    ~H"""
    <%!-- Wrapped so the search/tag JS can hide a whole folder (header + grid)
          once filtering empties it. --%>
    <section class="bmgroup">
      <h3 :if={@name} class="folder">{@name}</h3>
      <div class="grid">
        <.card :for={entry <- @items} entry={entry} />
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true

  defp card(assigns) do
    assigns =
      assign(assigns, %{
        tags: List.wrap(assigns.entry["tags"]),
        favicon: Bookmarks.favicon_url(assigns.entry["url"])
      })

    ~H"""
    <div class="card" data-search={haystack(@entry, @tags)} data-tags={Enum.join(@tags, " ")}>
      <a href={safe_href(@entry["url"])}>
        <div class="head">
          <img :if={@favicon} class="fav" src={@favicon} alt="" loading="lazy" />
          <span :if={!@favicon} class="fav"></span>
          <span class="label">{@entry["label"] || @entry["url"]}</span>
        </div>
        <div class="host">{host(@entry["url"])}</div>
        <span :if={@tags != []} class="tags">
          <span :for={tag <- @tags} class="tag">{tag}</span>
        </span>
      </a>
      <form class="rm" method="post" action="/browser/bookmarks/remove">
        <input type="hidden" name="url" value={@entry["url"]} />
        <button class="rm" type="submit" title="Remove bookmark" aria-label="Remove bookmark">
          &times;
        </button>
      </form>
    </div>
    """
  end

  defp tags_of(entries) do
    entries |> Enum.flat_map(&List.wrap(&1["tags"])) |> Enum.uniq() |> Enum.sort()
  end

  defp haystack(entry, tags) do
    [entry["label"], entry["url"], entry["folder"] | tags]
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  defp host(url) do
    case URI.parse(to_string(url)) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> to_string(url)
    end
  end

  # A clickable href allowlist: only http(s) and scheme-less (workspace) paths
  # like "/library/notes.md" survive as links. A `javascript:`/`data:`/etc.
  # scheme is neutralised to "#" so an escaped-but-clickable link can't run.
  # HEEx escaping does NOT cover this — see the moduledoc.
  defp safe_href(raw_url) do
    url = to_string(raw_url)

    case URI.parse(url) do
      %URI{scheme: nil} -> url
      %URI{scheme: scheme} when scheme in ["http", "https"] -> url
      _ -> "#"
    end
  end
end
